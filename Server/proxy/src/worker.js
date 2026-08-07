/**
 * RoutePic generation proxy.
 *
 * DESIGN.md §8.3. The app holds no provider keys and sends no coordinates; this
 * service is the only thing that spends money, and the only thing that has to
 * be trusted with the shape of somebody's route.
 *
 * Storage bindings expected:
 *   JOBS    — KV, job records keyed by id, and idempotency keys → job id
 *   QUOTA   — KV, per-device ledger
 *   OBJECTS — R2, generated images with a 7-day lifecycle rule
 */

const JOB_TTL_SECONDS = 60 * 60 * 24;
const OBJECT_TTL_SECONDS = 60 * 60 * 24 * 7;
const JOB_EXPIRY_MS = 10 * 60 * 1000;
const FREE_MONTHLY_ALLOWANCE = 8;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    try {
      if (request.method === 'POST' && url.pathname === '/jobs') {
        return await submitJob(request, env, ctx);
      }
      const pollMatch = url.pathname.match(/^\/jobs\/([A-Za-z0-9-]+)$/);
      if (request.method === 'GET' && pollMatch) {
        return await pollJob(pollMatch[1], request, env);
      }
      const cancelMatch = url.pathname.match(/^\/jobs\/([A-Za-z0-9-]+)\/cancel$/);
      if (request.method === 'POST' && cancelMatch) {
        return await cancelJob(cancelMatch[1], request, env);
      }
      if (request.method === 'GET' && url.pathname === '/quota') {
        return await readQuota(request, env);
      }
      return json({ error: 'not_found' }, 404);
    } catch (error) {
      // The message is deliberately generic: an error string can echo the
      // request body, and the request body is the user's route shape.
      console.error('request failed', error.name);
      return json({ error: 'internal_error' }, 500);
    }
  },
};

/* ------------------------------------------------------------------ submit */

async function submitJob(request, env, ctx) {
  const device = await authenticate(request, env);
  if (!device) return json({ error: 'unauthorized' }, 401);

  const idempotencyKey = request.headers.get('Idempotency-Key');
  if (!idempotencyKey) {
    // Without this a dropped response turns one picture into two charges.
    return json({ error: 'idempotency_key_required' }, 400);
  }

  const existingID = await env.JOBS.get(idempotencyKeyName(device, idempotencyKey));
  if (existingID) {
    const existing = await env.JOBS.get(existingID, 'json');
    if (existing) return json(publicJob(existing));
  }

  const body = await request.json();
  const validation = validateRequest(body);
  if (validation) return json({ error: validation }, 400);

  // One in flight per device: a queue of twenty is either a bug or an attack,
  // and either way it is the user's money.
  const inFlight = await env.JOBS.get(inFlightName(device));
  if (inFlight) return json({ error: 'already_generating' }, 409);

  const quota = await reserveQuota(env, device, idempotencyKey);
  if (!quota.ok) {
    return json({ error: 'quota_exhausted', remaining: quota.remaining }, 402);
  }

  const job = {
    id: crypto.randomUUID(),
    device,
    idempotencyKey,
    status: 'queued',
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    candidates: [],
  };

  await env.JOBS.put(job.id, JSON.stringify(job), { expirationTtl: JOB_TTL_SECONDS });
  await env.JOBS.put(idempotencyKeyName(device, idempotencyKey), job.id, {
    expirationTtl: JOB_TTL_SECONDS,
  });
  await env.JOBS.put(inFlightName(device), job.id, { expirationTtl: 900 });

  ctx.waitUntil(runGeneration(job, body, env));
  return json(publicJob(job), 202);
}

function validateRequest(body) {
  if (!body || !Array.isArray(body.orientationImages)) return 'orientation_images_required';
  if (body.orientationImages.length !== 16) return 'expected_16_orientations';
  if (!body.fingerprint) return 'fingerprint_required';

  // Refuse anything that looks like a coordinate. The client does not send them
  // (DESIGN.md §11); this is the check that keeps a future client change from
  // quietly starting to.
  const forbidden = ['latitude', 'longitude', 'lat', 'lon', 'coordinates', 'points'];
  const keys = collectKeys(body).map((key) => key.toLowerCase());
  if (keys.some((key) => forbidden.includes(key))) return 'location_data_rejected';

  return null;
}

function collectKeys(value, depth = 0) {
  if (depth > 6 || value === null || typeof value !== 'object') return [];
  if (Array.isArray(value)) return value.flatMap((item) => collectKeys(item, depth + 1));
  return Object.entries(value).flatMap(([key, child]) => [key, ...collectKeys(child, depth + 1)]);
}

/* ------------------------------------------------------------------ pipeline */

async function runGeneration(job, body, env) {
  await updateJob(env, job.id, { status: 'running' });

  try {
    const interpretation = await interpretShape(body, env);
    const chosen = interpretation.candidates[0] ?? {
      subject: interpretation.fallbackAbstract,
      why: 'Nothing recognisable, so the shape is drawn as an object instead.',
      renderIndex: 0,
      prompt: interpretation.fallbackAbstract,
    };

    const images = await generateImages(body, chosen, env);
    const candidates = [];
    for (const image of images) {
      const key = `${job.id}/${crypto.randomUUID()}.png`;
      await env.OBJECTS.put(key, image.bytes, {
        httpMetadata: { contentType: 'image/png' },
        customMetadata: { expiresAt: String(Date.now() + OBJECT_TTL_SECONDS * 1000) },
      });
      candidates.push({
        imageURL: await signedURL(env, key),
        subject: chosen.subject,
        why: chosen.why,
        seed: image.seed,
        controlStrength: body.controlStrength,
        renderIndex: chosen.renderIndex,
        costCents: image.costCents,
      });
    }

    await updateJob(env, job.id, { status: 'succeeded', candidates });
    await commitQuota(env, job.device, job.idempotencyKey);
  } catch (error) {
    console.error('generation failed', error.name);
    await updateJob(env, job.id, {
      status: 'failed',
      failureReason: 'The picture service did not return an image.',
    });
    await refundQuota(env, job.device, job.idempotencyKey);
  } finally {
    await env.JOBS.delete(inFlightName(job.device));
  }
}

/**
 * Stage 1 — the VLM picks an orientation and a subject (DESIGN.md §7.2).
 * All 16 renders go in at once so the model compares rather than predicting an
 * angle, which cross-review established is not stable geometry.
 */
async function interpretShape(body, env) {
  const response = await fetch(env.VLM_ENDPOINT, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      authorization: `Bearer ${env.VLM_API_KEY}`,
    },
    body: JSON.stringify({
      model: env.VLM_MODEL,
      orientations: body.orientationImages,
      fingerprint: body.fingerprint,
      instruction:
        'Each image is one orientation of the same GPS route. Pick the orientation ' +
        'that most resembles an animal or object, name up to three subjects, and for ' +
        'each explain in one sentence which part of the line suggested it. If nothing ' +
        'is recognisable, say so and propose an abstract object instead.',
    }),
  });
  if (!response.ok) throw new Error('vlm_failed');
  return response.json();
}

/** Stage 2 — conditioned generation (DESIGN.md §7.3). */
async function generateImages(body, chosen, env) {
  const response = await fetch(env.IMAGE_ENDPOINT, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      authorization: `Bearer ${env.IMAGE_API_KEY}`,
    },
    body: JSON.stringify({
      model: env.IMAGE_MODEL,
      control_image: body.orientationImages[chosen.renderIndex],
      control_mode: body.conditionMode,
      control_strength: body.controlStrength,
      prompt: `${chosen.prompt}, ${body.stylePreset}`,
      num_outputs: 2,
    }),
  });
  if (!response.ok) throw new Error('image_failed');

  const payload = await response.json();
  return Promise.all(
    payload.images.map(async (entry) => ({
      bytes: await (await fetch(entry.url)).arrayBuffer(),
      seed: entry.seed,
      costCents: entry.cost_cents ?? 0,
    }))
  );
}

/* ------------------------------------------------------------------ polling */

async function pollJob(id, request, env) {
  const device = await authenticate(request, env);
  if (!device) return json({ error: 'unauthorized' }, 401);

  const job = await env.JOBS.get(id, 'json');
  if (!job) return json({ error: 'not_found' }, 404);
  if (job.device !== device) return json({ error: 'not_found' }, 404);

  // A job the worker abandoned mid-flight would otherwise sit at "running"
  // forever, holding a reservation the user never gets back.
  if (
    !isTerminal(job.status) &&
    Date.now() - Date.parse(job.createdAt) > JOB_EXPIRY_MS
  ) {
    await updateJob(env, id, { status: 'expired' });
    await refundQuota(env, device, job.idempotencyKey);
    await env.JOBS.delete(inFlightName(device));
    job.status = 'expired';
  }

  return json(publicJob(job));
}

async function cancelJob(id, request, env) {
  const device = await authenticate(request, env);
  if (!device) return json({ error: 'unauthorized' }, 401);

  const job = await env.JOBS.get(id, 'json');
  if (!job || job.device !== device) return json({ error: 'not_found' }, 404);
  if (isTerminal(job.status)) return json(publicJob(job));

  await updateJob(env, id, { status: 'cancelled' });
  await refundQuota(env, device, job.idempotencyKey);
  await env.JOBS.delete(inFlightName(device));
  return json({ ...publicJob(job), status: 'cancelled' });
}

/* ------------------------------------------------------------------ quota */

async function reserveQuota(env, device, key) {
  const ledger = await loadLedger(env, device);
  if (ledger.reservations[key]) return { ok: true, remaining: remaining(ledger) };
  if (remaining(ledger) <= 0) return { ok: false, remaining: 0 };

  ledger.reservations[key] = 1;
  await saveLedger(env, device, ledger);
  return { ok: true, remaining: remaining(ledger) };
}

async function commitQuota(env, device, key) {
  const ledger = await loadLedger(env, device);
  if (!ledger.reservations[key]) return;
  delete ledger.reservations[key];
  ledger.used += 1;
  await saveLedger(env, device, ledger);
}

async function refundQuota(env, device, key) {
  const ledger = await loadLedger(env, device);
  if (!ledger.reservations[key]) return;
  delete ledger.reservations[key];
  await saveLedger(env, device, ledger);
}

async function readQuota(request, env) {
  const device = await authenticate(request, env);
  if (!device) return json({ error: 'unauthorized' }, 401);

  const ledger = await loadLedger(env, device);
  return json({
    allowance: ledger.allowance,
    used: ledger.used,
    remaining: remaining(ledger),
    periodStart: ledger.periodStart,
  });
}

async function loadLedger(env, device) {
  const stored = await env.QUOTA.get(`ledger:${device}`, 'json');
  const period = currentPeriod();
  if (!stored || stored.periodStart !== period) {
    // Reservations survive a period boundary: a job still running has to be
    // committed or refunded regardless of which month it started in.
    return {
      allowance: FREE_MONTHLY_ALLOWANCE,
      used: 0,
      periodStart: period,
      reservations: stored?.reservations ?? {},
    };
  }
  return stored;
}

async function saveLedger(env, device, ledger) {
  await env.QUOTA.put(`ledger:${device}`, JSON.stringify(ledger));
}

function remaining(ledger) {
  return Math.max(0, ledger.allowance - ledger.used - Object.keys(ledger.reservations).length);
}

function currentPeriod() {
  const now = new Date();
  return `${now.getUTCFullYear()}-${String(now.getUTCMonth() + 1).padStart(2, '0')}`;
}

/* ------------------------------------------------------------------ helpers */

/**
 * App Attest establishes that the caller is a genuine install of this app.
 *
 * It is not identity and it is not entitlement (DESIGN.md §8.3): a reinstall
 * produces a new key and therefore a fresh free allowance. That is why the free
 * tier is small and anything paid goes through StoreKit receipt verification.
 */
async function authenticate(request, env) {
  const assertion = request.headers.get('X-Device-Attestation');
  if (!assertion || assertion.length < 16) return null;

  // TODO before production: verify against Apple's App Attest service.
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(assertion));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

async function signedURL(env, key) {
  return `${env.PUBLIC_OBJECT_BASE}/${key}`;
}

async function updateJob(env, id, patch) {
  const job = await env.JOBS.get(id, 'json');
  if (!job) return;
  const updated = { ...job, ...patch, updatedAt: new Date().toISOString() };
  await env.JOBS.put(id, JSON.stringify(updated), { expirationTtl: JOB_TTL_SECONDS });
}

function isTerminal(status) {
  return status === 'succeeded' || status === 'failed'
    || status === 'cancelled' || status === 'expired';
}

/** The device id and the raw request never leave this service. */
function publicJob(job) {
  return {
    id: job.id,
    idempotencyKey: job.idempotencyKey,
    status: job.status,
    createdAt: job.createdAt,
    updatedAt: job.updatedAt,
    candidates: job.candidates ?? [],
    failureReason: job.failureReason,
  };
}

function idempotencyKeyName(device, key) {
  return `idem:${device}:${key}`;
}

function inFlightName(device) {
  return `inflight:${device}`;
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

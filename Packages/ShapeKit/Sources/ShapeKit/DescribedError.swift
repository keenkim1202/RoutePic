import Foundation

/// An error whose `description` is the sentence a person should read.
///
/// `localizedDescription` comes from `LocalizedError`, never from
/// `CustomStringConvertible`. An error that carefully writes one and conforms
/// only to the latter shows "Failure error 2" in an alert — fourteen of them
/// did, against three that had been fixed one at a time as they were noticed.
public protocol DescribedError: Error, CustomStringConvertible, LocalizedError {}

extension DescribedError {
    public var errorDescription: String? { description }
}

/// How the camera follows the user's location.
public enum FollowMode: Sendable, Equatable {
    /// The camera stays where it is.
    case none
    /// The camera keeps the user's position in the centre.
    case position
    /// The camera keeps the user's position in the centre and turns with the device's heading. With
    /// ``UserLocationMode/provided`` nothing gives the map a heading, so the camera follows the position only.
    case heading
    /// The camera keeps the user's position in the centre and turns with the direction of travel.
    case course
}

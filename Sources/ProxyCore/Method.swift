import Protocol

func methodFromRaw(_ rawValue: String) -> HTTPMethod {
    HTTPMethod(rawValue: rawValue.uppercased()) ?? .get
}

import Foundation

// Public identifiers of the official app's Amplify configuration. The Amplify
// app client has no secret, so no request carries a SECRET_HASH.
enum CognitoConfig {
    static let region = "us-east-1"
    static let userPoolID = "us-east-1_s6T1EfUgP"
    static let clientID = "2tl54vtfepvo3nu23um3c6rjs9"
    static let identityPoolID = "us-east-1:656722e8-449d-43c5-958b-987700bc70e8"
    static let identityProvider = "cognito-idp.us-east-1.amazonaws.com/us-east-1_s6T1EfUgP"
    static let userPoolEndpoint = URL(string: "https://cognito-idp.us-east-1.amazonaws.com/")!
    static let identityEndpoint = URL(string: "https://cognito-identity.us-east-1.amazonaws.com/")!
}

enum CognitoRequest {
    static func initiateAuth(username: String, password: String) throws -> URLRequest {
        try userPool("InitiateAuth", [
            "AuthFlow": "USER_PASSWORD_AUTH",
            "ClientId": CognitoConfig.clientID,
            "AuthParameters": ["USERNAME": username, "PASSWORD": password],
        ])
    }

    static func refresh(refreshToken: String) throws -> URLRequest {
        try userPool("InitiateAuth", [
            "AuthFlow": "REFRESH_TOKEN_AUTH",
            "ClientId": CognitoConfig.clientID,
            "AuthParameters": ["REFRESH_TOKEN": refreshToken],
        ])
    }

    private static func userPool(_ action: String, _ body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: CognitoConfig.userPoolEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue("AWSCognitoIdentityProviderService.\(action)", forHTTPHeaderField: "X-Amz-Target")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        request.timeoutInterval = 20
        return request
    }
}

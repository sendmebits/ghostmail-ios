import Foundation

/// Shared validation utilities for input validation across the application
enum ValidationUtils {
    
    // MARK: - Email Validation
    
    /// Validates email address format to prevent injection attacks
    /// Uses a simple but effective regex pattern that covers most valid email formats
    /// - Parameter email: The email address to validate
    /// - Returns: true if the email is valid, false otherwise
    static func isValidEmailAddress(_ email: String) -> Bool {
        let emailPattern = "^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$"
        let emailPredicate = NSPredicate(format: "SELF MATCHES %@", emailPattern)
        return emailPredicate.evaluate(with: email)
    }
    
    // MARK: - URL Validation
    
    /// Validates that a URL string doesn't contain malicious schemes
    /// - Parameter urlString: The URL string to validate
    /// - Returns: true if the URL is safe, false if it contains dangerous schemes
    static func isSafeURLScheme(_ urlString: String) -> Bool {
        let lowercased = urlString.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Block potentially dangerous schemes
        let dangerousSchemes = ["javascript:", "data:", "file:"]
        for scheme in dangerousSchemes {
            if lowercased.hasPrefix(scheme) {
                return false
            }
        }
        
        return true
    }
    
    // MARK: - Input Sanitization
    
    /// Sanitizes input to remove potentially dangerous characters
    /// - Parameter input: The string to sanitize
    /// - Returns: Sanitized string with dangerous characters removed
    static func sanitizeInput(_ input: String) -> String {
        // Remove potentially dangerous characters that could be used in injection attacks
        let dangerousChars = CharacterSet(charactersIn: "\n\r\t<>\"'\\")
        return input.components(separatedBy: dangerousChars).joined()
    }
}

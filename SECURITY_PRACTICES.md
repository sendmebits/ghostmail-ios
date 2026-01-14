# Security Best Practices for Ghost Mail iOS Development

This document outlines security best practices that should be followed when developing and maintaining the Ghost Mail iOS application.

## Table of Contents
1. [Credential Management](#credential-management)
2. [Network Security](#network-security)
3. [Input Validation](#input-validation)
4. [Data Storage](#data-storage)
5. [Logging](#logging)
6. [Code Review Checklist](#code-review-checklist)

## Credential Management

### DO ✅

- **Always use Keychain for sensitive data**
  ```swift
  KeychainHelper.shared.save(apiToken, service: "ghostmail", account: "apiToken")
  ```

- **Use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`**
  ```swift
  kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
  ```

- **Delete credentials on logout**
  ```swift
  KeychainHelper.shared.delete(service: "ghostmail", account: "apiToken")
  ```

### DON'T ❌

- **Never store credentials in UserDefaults**
  ```swift
  // WRONG - DON'T DO THIS
  UserDefaults.standard.set(apiToken, forKey: "apiToken")
  ```

- **Never hardcode credentials**
  ```swift
  // WRONG - DON'T DO THIS
  let apiToken = "sk-1234567890abcdef"
  ```

- **Never log full credentials**
  ```swift
  // WRONG - DON'T DO THIS
  print("API Token: \(apiToken)")
  ```

## Network Security

### DO ✅

- **Always use HTTPS for API calls**
  ```swift
  private var baseURL = "https://api.cloudflare.com/client/v4"
  ```

- **Validate TLS certificates**
  ```swift
  sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { ... })
  ```

- **Set minimum TLS version to 1.2**
  ```swift
  sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)
  ```

- **Handle network errors gracefully**
  ```swift
  guard let httpResponse = response as? HTTPURLResponse else {
      throw CloudflareError(message: "Invalid response")
  }
  ```

### DON'T ❌

- **Never allow plain HTTP connections**
  ```swift
  // WRONG - DON'T DO THIS
  private var baseURL = "http://api.example.com"
  ```

- **Never disable certificate validation**
  ```swift
  // WRONG - DON'T DO THIS (example of what NOT to do)
  session.configuration.tlsMinimumSupportedProtocolVersion = .TLSv10
  ```

## Input Validation

### DO ✅

- **Validate email addresses**
  ```swift
  guard isValidEmailAddress(emailAddress) else {
      throw CloudflareError(message: "Invalid email address format")
  }
  ```

- **Validate URLs from user input or deep links**
  ```swift
  guard !sanitized.lowercased().hasPrefix("javascript:"),
        !sanitized.lowercased().hasPrefix("data:"),
        !sanitized.lowercased().hasPrefix("file:") else {
      print("[Security] Blocked potentially malicious URL scheme")
      return nil
  }
  ```

- **Sanitize string inputs**
  ```swift
  let sanitized = input.trimmingCharacters(in: .whitespacesAndNewlines)
  ```

- **Use type-safe queries with SwiftData**
  ```swift
  let descriptor = FetchDescriptor<EmailAlias>(
      predicate: #Predicate<EmailAlias> { alias in
          alias.emailAddress == emailAddress
      }
  )
  ```

### DON'T ❌

- **Never concatenate user input into queries**
  ```swift
  // WRONG - this is for SQL but shows the pattern to avoid
  let query = "SELECT * FROM users WHERE email = '\(userInput)'"
  ```

- **Never trust external input without validation**
  ```swift
  // WRONG - DON'T DO THIS
  func processURL(_ urlString: String) {
      let url = URL(string: urlString)! // No validation!
      // ... process url
  }
  ```

## Data Storage

### DO ✅

- **Use SwiftData for app data**
  ```swift
  @Model
  final class EmailAlias {
      var emailAddress: String = ""
      // ... other properties
  }
  ```

- **Enable iCloud sync only for non-sensitive data**
  ```swift
  @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled: Bool = true
  ```

- **Use Keychain for sensitive data**
  - API tokens
  - Passwords
  - Private keys

### DON'T ❌

- **Never store sensitive data in UserDefaults**
  ```swift
  // WRONG - DON'T DO THIS
  UserDefaults.standard.set(password, forKey: "password")
  ```

- **Never store unencrypted sensitive data in files**
  ```swift
  // WRONG - DON'T DO THIS
  try apiToken.write(to: fileURL, atomically: true, encoding: .utf8)
  ```

## Logging

### DO ✅

- **Mask sensitive IDs in logs**
  ```swift
  private func maskId(_ value: String) -> String {
      return "\(value.prefix(2))…\(value.suffix(4))"
  }
  print("Zone ID: \(maskId(zoneId))")
  ```

- **Log security events**
  ```swift
  print("[Security] Blocked potentially malicious URL scheme")
  ```

- **Use structured logging**
  ```swift
  print("[Cloudflare] Token verification successful")
  ```

### DON'T ❌

- **Never log full API tokens**
  ```swift
  // WRONG - DON'T DO THIS
  print("Token: \(apiToken)")
  ```

- **Never log passwords**
  ```swift
  // WRONG - DON'T DO THIS
  print("Password: \(password)")
  ```

- **Never log full API response bodies that might contain sensitive data**
  ```swift
  // WRONG - DON'T DO THIS (unless you know it's safe)
  print("Response: \(String(data: data, encoding: .utf8))")
  ```

## Code Review Checklist

When reviewing code changes, check for:

### Credentials
- [ ] No hardcoded credentials
- [ ] Sensitive data stored in Keychain
- [ ] Proper cleanup on logout
- [ ] No credentials in logs

### Network
- [ ] HTTPS used for all external requests
- [ ] TLS certificate validation enabled
- [ ] Minimum TLS 1.2
- [ ] Error handling for network failures

### Input Validation
- [ ] Email addresses validated
- [ ] URLs validated (especially from deep links)
- [ ] User input sanitized
- [ ] No SQL injection vulnerabilities
- [ ] SwiftData queries use Predicate

### Data Storage
- [ ] Sensitive data not in UserDefaults
- [ ] Keychain used appropriately
- [ ] Proper accessibility settings
- [ ] iCloud sync appropriate for data type

### Logging
- [ ] No sensitive data in logs
- [ ] IDs properly masked
- [ ] Security events logged
- [ ] Error messages don't reveal sensitive info

### Dependencies
- [ ] Dependencies from trusted sources
- [ ] Regular security updates
- [ ] Known vulnerabilities checked

## Security Testing

### Manual Testing
1. Test with invalid input (email addresses, URLs)
2. Test deep link handling with malicious payloads
3. Verify logout clears all sensitive data
4. Check Keychain contents before/after operations
5. Monitor network traffic with proxy

### Automated Testing
1. Run static analysis tools
2. Check for common vulnerabilities
3. Dependency vulnerability scanning
4. Code linting for security patterns

## Incident Response

If a security vulnerability is discovered:

1. **Assess the severity**
   - What data is at risk?
   - How many users are affected?
   - Is it being actively exploited?

2. **Contain the issue**
   - Can it be fixed immediately?
   - Should the app be temporarily disabled?
   - Do users need to be notified?

3. **Fix the vulnerability**
   - Implement the fix
   - Test thoroughly
   - Review related code

4. **Deploy the fix**
   - Emergency release if critical
   - Update version notes
   - Notify affected users if needed

5. **Post-mortem**
   - Document the vulnerability
   - Update security practices
   - Share learnings with team

## Resources

- [OWASP Mobile Security Project](https://owasp.org/www-project-mobile-security/)
- [Apple Security Documentation](https://developer.apple.com/documentation/security)
- [iOS Security Guide](https://support.apple.com/guide/security/welcome/web)
- [Swift Security Best Practices](https://swift.org/security/)

## Updates

This document should be reviewed and updated:
- When new security features are added
- When vulnerabilities are discovered
- Quarterly as a routine review
- When Apple releases new security guidelines

---

**Last Updated:** 2026-01-14  
**Next Review:** 2026-04-14

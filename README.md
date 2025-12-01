<div align="center">
  
# <img width="32" height="32" alt="Ghostmail_gpt_dark_FULL" src="https://github.com/user-attachments/assets/9bae55b4-3201-47a8-b801-33123aa86b4d" />  Ghost Mail for iPhone

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-iOS%2018%2B-blue?style=flat-square)]()
[![Release](https://img.shields.io/github/v/release/sendmebits/ghostmail-ios.svg?style=flat-square)](https://github.com/sendmebits/ghostmail-ios/releases)
[![Issues](https://img.shields.io/github/issues/sendmebits/ghostmail-ios?style=flat-square)](https://github.com/sendmebits/ghostmail-ios/issues)
[![Pull Requests](https://img.shields.io/github/issues-pr/sendmebits/ghostmail-ios?style=flat-square)](https://github.com/sendmebits/ghostmail-ios/pulls)

[<img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="App Store Download" height="40">](https://apps.apple.com/app/ghost-mail/id6741405019)

</div>

Ghost Mail is a free and open-source iPhone app to manage email alias' for Cloudflare hosted domains. It lets you quickly create disposable email addresses on the fly, shielding your main email from unwanted messages, data breaches, tracking and targeted ads. With full open-source transparency enjoy peace of mind knowing that your primary email address is being kept private!

**Ghost Mail Features:**
- 📵 Easily ghost spammers by disabling or deleting aliases
- ✉️ Create private email aliases on the fly
- 🔒 Protects your main email from being exposed in breaches
- 🛠️ Verifiable 100% open-source software with no paywalls
- 📋 View all of your email aliases while offline
- 📨 Add multiple email domains
- 💾 Sync to iCloud + CSV import/export
- 📧 Send email from email aliases
- 📨 Email analytics and charts

<p align="center">
  <img src="https://github.com/user-attachments/assets/671ba0ab-f795-44c6-8916-4c01d71585f5" alt="Alias List" width="250">
  <img src="https://github.com/user-attachments/assets/242a78f4-5535-49da-8b1e-226bc49651b5" alt="Email Alias" width="250">
  <img src="https://github.com/user-attachments/assets/8d748a23-ac4f-4817-8ad1-8f7ddb1ea077" alt="Create Alias" width="250">
</p>

# Pre-requisites

1. You must have a domain hosted by Cloudflare - https://cloudflare.com/
2. <code>Cloudflare.com > <domain.com> > Email > Email Routing</code> must be enabled
3. At least 1 verified destination email addresses must have been created:
       <code>Cloudflare.com > <domain.com> > Email > Email Routing > Destination Addresses</code> 

# How to login

Log in to your Cloudflare dashboard, choose a zone/domain, and copy Account ID and Zone ID from your domain's overview page.

Go to Profile > <a href="https://dash.cloudflare.com/profile/api-tokens">API Tokens</a> > Create new token (then choose Custom token)

Token Permissions:
1. Account > Email Routing Addresses > **Read**
2. Zone > Email Routing Rules > **Edit**
3. Zone > Zone Settings > **Read**
4. Zone > Analytics > **Read**  _(OPTIONAL but recommended: Required for email statistcs and charts)_
5. Zone > DNS > **Read**  _(OPTIONAL: Only required subdomains are going to be used)_


# Use the CSV import feature to quickly bulk add new email alias entries

CSV formatting is as follows, note the optional fields:

```
Email Address,Website,Notes,Created,Enabled,Forward To
user@domain.com,website.com[optional],notes[optional],2025-02-07T01:39:10Z[optional],true,forwardto@domain.com
```

CSV import notes:
- On import, the app infers the target zone from the email domain in `Email Address`.
- If no configured zone matches the email's domain, the current primary zone is used as a fallback.
- Imports will update and overwrite existing; review after importing.

# Ghost Mail Privacy
- Ghost Mail does not have any servers or infrastructure that it connects to.
- The iPhone app connects directly to Cloudflare using your API token with minimal permissions, no middle man.
- Cloudflare token is stored securely in the iPhone keychain.
- SMTP credentials (if confgiured for sending email) are also securely stored in the iPhone keychain.
- Email aliases and metadata (website, notes, date) are optionally synced to your iCloud account for backup purposes. This can be enabled/disabled in settings.

# Privacy
- Ghost Mail does not use any servers or external infrastructure; all actions happen directly from your device.
- The app talks directly to Cloudflare using your API token with minimal required permissions; there is no intermediary service.
- Your Cloudflare API token is stored securely in the iOS Keychain.
- SMTP credentials (if you configure sending email) are also stored securely in the iOS Keychain.
- Email aliases and their metadata (website, notes, dates) can optionally sync to your iCloud account for backup; you can turn this on or off in Settings at any time.

# Why Use Email Aliases

Email aliases protect your primary inbox from spam, phishing, and long-term exposure. Instead of handing out your real email, you give out an alias that can be turned off or deleted if abused. This helps maintain privacy and reduces the risk of account compromise.
- CISA guidance: <a href=https://www.cisa.gov/news-events/news/reducing-spam>Reducing Spam</a> – U.S. Cybersecurity & Infrastructure Security Agency warns against exposing your primary email address publicly.
- Expert opinion: <a href=https://krebsonsecurity.com/2022/08/the-security-pros-and-cons-of-using-email-aliases/>Brian Krebs on Email Aliases</a> – Security journalist Brian Krebs outlines the advantages and trade-offs of using aliases.

Aliases act as disposable shields for your identity, keeping your real account secure while still letting you receive messages when you want.

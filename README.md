# Ghost Mail for iPhone

Ghost Mail open-source email alias manager for Cloudflare hosted domains. It lets you quickly create disposable email addresses on the fly, shielding your main email from unwanted messages, data breaches, tracking and targeted ads. With full open-source transparency enjoy peace of mind knowing that your primary email address is being kept private!

**Ghost Mail Features:**  
- 📵 Easily ghost spammers by disabling or deleting aliases  
- ✉️ Create private email aliases on the fly  
- 🔒 Protects your main email from being exposed in breaches  
- 🛠️ Verifiable 100% open-source software with no paywalls  
- 📋 View all of your email aliases while offline  

<p>
  <img src="https://github.com/user-attachments/assets/c1fa8003-89de-42c1-8998-117be54d11a9" alt="Alias List" width="250">
  <img src="https://github.com/user-attachments/assets/0e87e6e7-e419-4e3c-b69f-53957ff7ffa7" alt="Create Alias" width="250">
  <img src="https://github.com/user-attachments/assets/0bbf15cb-9b54-4337-a7fa-ff5e12e0e0a2" alt="Email Alias" width="250">
</p>


# Pre-requisites

1. You must have a domain hosted by Cloudflare - https://cloudflare.com/
2. <code>Cloudflare.com > <domain.com> > Email > Email Routing</code> must be enabled
3. At least 1 verified destination email addresses must have been created:
       <code>Cloudflare.com > <domain.com> > Email > Email Routing > Destination Addresses</code> 

# Use the CSV import feature to quickly bulk add new email alias entries

CSV formatting is as follows, note the optional fields:

```
Email Address,Website,Notes,Created,Enabled,Forward To
user@domain.com,website.com[optional],notes[optional],2025-02-07T01:39:10Z[optional],true,forwardto@domain.com
```

Multi-zone notes:
- The CSV export lists aliases across all configured zones and does not include a zone column.
- On import, the app infers the target zone from the email domain in `Email Address` and applies the Cloudflare change in that domain's zone.
- If no configured zone matches the email's domain, the current primary zone is used as a fallback.
- Existing aliases keep their original zone when present; otherwise the zone is set based on the inferred domain.
- Import may create duplicates if you have the same address in multiple zones; review after importing.

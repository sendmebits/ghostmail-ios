# Ghost Mail for iPhone

Ghost Mail open-source email alias manager for Cloudflare hosted domains. It lets you quickly create disposable email addresses on the fly, shielding your main email from unwanted messages, data breaches, tracking and targeted ads. With full open-source transparency enjoy peace of mind knowing that your primary email address is being kept private!

**Ghost Mail Features:**  
- 📵 Easily ghost spammers by disabling or deleting aliases  
- ✉️ Create private email aliases on the fly  
- 🔒 Protects your main email from being exposed in breaches  
- 🛠️ Verifiable 100% open-source software with no paywalls  
- 📋 View all of your email aliases while offline  

<p>
  <img src="https://github.com/user-attachments/assets/46511a00-3bf7-49d3-b26d-5fa96e008513" alt="Alias List" width="300">
  <img src="https://github.com/user-attachments/assets/6ade2e1b-b9a3-4731-8c99-f8a6b469723f" alt="Create Alias" width="300">
  <img src="https://github.com/user-attachments/assets/c27d7216-84e2-4ab7-b2b3-076b25a412e0" alt="Email Alias" width="300">
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

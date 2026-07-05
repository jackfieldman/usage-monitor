# Signing & notarizing a distributable build

Building from source ad-hoc signs the app, which is fine for personal use. To
hand out a **downloadable** `.app` that opens with a normal double-click on
anyone's Mac, it must be signed with a **Developer ID Application** certificate
and **notarized** by Apple. This is a one-time setup; after it, `./release.sh`
does everything.

You need a **paid Apple Developer Program** membership ($99/yr) — a free Apple
ID cannot issue Developer ID certificates.

## 1. Create the Developer ID Application certificate

Keep the private key in your keychain (don't generate loose key files).

1. Open **Keychain Access** → menu **Keychain Access ▸ Certificate Assistant ▸
   Request a Certificate From a Certificate Authority…**
2. Enter your email, leave **CA Email** blank, choose **Saved to disk**, and
   **Let me specify key pair information** → Continue. Use **2048 bits / RSA**.
   Save `CertificateSigningRequest.certSigningRequest`.
3. Go to <https://developer.apple.com/account/resources/certificates/add>,
   choose **Developer ID Application**, upload the CSR, and download the
   resulting `developerID_application.cer`.
4. Double-click the `.cer` to install it. It pairs with the private key already
   in your keychain, becoming a valid signing identity.

Verify:

```sh
security find-identity -v -p codesigning
# → should list  "Developer ID Application: Your Name (TEAMID)"
```

The 10-character `TEAMID` in parentheses is your Team ID (also at
<https://developer.apple.com/account> ▸ Membership).

## 2. Store notarization credentials

Create an **app-specific password** at <https://appleid.apple.com> ▸ Sign-In &
Security ▸ App-Specific Passwords. Then store it once for `notarytool`:

```sh
xcrun notarytool store-credentials usage-monitor \
  --apple-id you@example.com \
  --team-id TEAMID \
  --password xxxx-xxxx-xxxx-xxxx      # the app-specific password
```

This saves the profile named `usage-monitor` in your keychain. Nothing secret
is stored in the repo.

## 3. Cut a release

```sh
./release.sh
```

It builds, signs with hardened runtime, notarizes (waits for Apple), staples
the ticket, and writes `dist/UsageMonitor.zip` — ready to upload to a GitHub
Release. Recipients just unzip and open.

## Publishing the download

```sh
gh release create v1.0 dist/UsageMonitor.zip \
  --title "Usage Monitor 1.0" --notes "First release."
```

Then people can grab the zip from the Releases page instead of building.

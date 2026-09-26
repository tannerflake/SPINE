# Apple Wallet library card: one-time setup

The code is fully built (functions/src/wallet.ts, SPINE/Services/WalletPassService.swift).
It cannot go live until the pass certificate exists and the two secrets are set.
Everything here is done once; step 6 is the only recurring chore.

## 1. Create the Pass Type ID (developer.apple.com, not App Store Connect)

Certificates, Identifiers & Profiles → Identifiers → "+" → **Pass Type IDs**.

- Identifier: `pass.com.wellread.app.librarycard` (hardcoded in functions/src/wallet.ts as PASS_TYPE_ID)
- Description: SPINE Library Card

## 2. Create the certificate

Certificates → "+" → Services → **Pass Type ID Certificate** → select the identifier above.

- CSR: Keychain Access → Certificate Assistant → Request a Certificate From a Certificate
  Authority → save to disk, upload it.
- Download the .cer and double-click to install it into the login keychain.

## 3. Export the cert + key as PEM

In Keychain Access, find "Pass Type ID: pass.com.wellread.app.librarycard", expand it,
select the certificate AND its private key together, right-click → Export → `spinepass.p12`
(pick any temporary password). Then:

```bash
openssl pkcs12 -in spinepass.p12 -clcerts -nokeys -legacy -out spinepass-cert.pem
```

```bash
openssl pkcs12 -in spinepass.p12 -nocerts -nodes -legacy -out spinepass-key.pem
```

(`-nodes` leaves the key unencrypted, which is what the function expects. If openssl
complains about `-legacy`, drop that flag.)

## 4. Set the secrets and deploy

```bash
firebase functions:secrets:set WALLET_PASS_CERT_PEM --data-file spinepass-cert.pem
```

```bash
firebase functions:secrets:set WALLET_PASS_KEY_PEM --data-file spinepass-key.pem
```

```bash
firebase deploy --only functions:createWalletPass,functions:updateWalletCardArt,functions:walletPassWebService
```

Then delete `spinepass.p12`, `spinepass-cert.pem`, and `spinepass-key.pem` from disk.

## 5. Verify the web service URL

The pass tells Wallet to call
`https://us-central1-wellread-520f2.cloudfunctions.net/walletPassWebService` (WEB_SERVICE_URL
in wallet.ts). After deploying, confirm that URL answers:

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://us-central1-wellread-520f2.cloudfunctions.net/walletPassWebService/v1/passes/pass.com.wellread.app.librarycard/nope
```

Expect `401` (unauthorized, which means it routed). If it is not reachable, get the real URL
from `firebase functions:list`, update WEB_SERVICE_URL, rebuild, redeploy.

## 6. Yearly: the certificate expires

Pass signing and the update pushes both die when the cert lapses (~1 year). Set a calendar
reminder a month before expiry; renewing is steps 2 to 4 again with the same Pass Type ID.

## How it works once live

- Your card page (avatar → card sheet) gains a **Wallet** button next to Share. It renders
  the strip art (paper band + OG mark + placed stamps) at 1x/2x/3x, sends it to
  `createWalletPass`, and presents the signed pass. Re-adding refreshes in place.
- Wallet registers the device with `walletPassWebService`; registrations live in
  `walletRegistrations`, per-member pass state (auth token, frozen card number) in
  `walletPasses`. Both are server-only.
- Every stamp press / move / removal re-renders the art and calls `updateWalletCardArt`,
  which stores it and APNs-pushes every registered device (empty push, signed with the same
  pass cert). Wallet then re-fetches the pass from the web service. Members without the pass
  cost one no-op call, debounced to once per stamping session.
- Debugging: Wallet posts client-side errors to the web service's `/v1/log`; read them with
  `firebase functions:log --only walletPassWebService`.

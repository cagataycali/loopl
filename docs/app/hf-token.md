# Hugging Face token

You do **not** need a token for anything in the default catalog — every `mlx-community` repo is public.
A token is only used for **gated** repositories (Llama, Gemma originals, …) that you have been granted
access to.

## Add one

1. Create a *read* token at [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens).
2. **Settings → Hugging Face token** → paste → *Save*.

## Where it goes

- The Keychain of the device, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. It is not synced to iCloud
  Keychain and not included in backups.
- It is sent as `Authorization: Bearer …` **only** to `https://huggingface.co` when a download is
  started, and only for the repo you tapped.
- It is never logged, never shown again in full (the field shows `hf_…1234`), never sent anywhere else.

**Remove** clears it from the Keychain immediately. The app keeps working with public models.

## In the SDK

```swift
let model = MLXModel("meta-llama/Llama-3.2-1B-Instruct", hfToken: token)
```

or hand `MLXModel` a `TokenProvider` closure if you keep the token in your own Keychain item.

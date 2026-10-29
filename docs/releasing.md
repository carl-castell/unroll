# Releasing

unroll is distributed only through the Homebrew tap `carl-castell/homebrew-tap`, built from source.
No binaries are published.

## One-time setup

1. Create the public repository `carl-castell/homebrew-tap` with a `Formula/` folder.
2. Create a fine-grained personal access token: GitHub → Settings → Developer settings →
   Fine-grained tokens. Repository access: only `carl-castell/homebrew-tap`.
   Permissions: Contents → Read and write.
3. In `carl-castell/unroll` → Settings → Secrets and variables → Actions, add it as `TAP_TOKEN`.

## Each release

1. Set the version in `Sources/unroll/Unroll.swift` (`let unrollVersion = "0.1.0"`) and commit.
2. Tag and push:

   ```sh
   git tag v0.1.0
   git push origin main v0.1.0
   ```

3. The Release workflow checks that the tag matches the version, builds and tests, creates the
   GitHub release, and writes `Formula/unroll.rb` with the tarball's URL and SHA-256 into the tap.
4. Afterwards, set the version back to the next development version, e.g. `0.2.0-dev`.

Users then install or update with:

```sh
brew install carl-castell/tap/unroll
brew upgrade unroll
```

## Later: homebrew-core

The project is kept compatible with a submission to homebrew-core: MIT license, builds from source,
stable tagged versions, no self-updating, and a `test do` block that runs without a device.

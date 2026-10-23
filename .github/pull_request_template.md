## What changes

Before:

After:

## How

<!-- A few sentences on the approach, and anything a reviewer should look at closely. -->

## Checks

- [ ] `Scripts/build-xcode.sh --test` passes
- [ ] New UI text is English and has a French translation in `Resources/Localizable.xcstrings`
- [ ] Nothing new runs on the audio thread that allocates, locks or does I/O
- [ ] Tried in the app, if the change is visible or audible

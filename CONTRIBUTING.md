# Contributing to Filmback

Thanks for helping. The most useful contribution right now is support for more Fujifilm cameras.

## Add your camera

You don't need to write code to start.

1. Connect the camera in Filmback and choose **Copy camera report**. This only reads from the camera, and the report leaves out the serial number.
2. [Open a camera report](https://github.com/ska2704/Filmback/issues/new?template=camera-report.yml) and paste it in.

If you can write Swift, [docs/ADDING_A_CAMERA.md](docs/ADDING_A_CAMERA.md) covers the rest.

## Build and test

You need a Mac with Xcode.

```sh
swift test --build-system native
./scripts/build-app.sh
```

The tests use a simulated camera, so they can't show that something works on real hardware. Say in your pull request what you ran on a real camera, including the model and firmware.

## Rules for camera code

A mistake here affects someone else's camera, so these aren't negotiable:

- **Never send an untested write.** A model gets write support only after each kind of write has been checked on that model.
- **Unknown values stay unknown.** Report them. Don't guess a mapping that could later be written to a bank.
- **Back up first, read back after.** Every write path saves the banks first and confirms the result afterwards.
- **No firmware changes, memory writes or deleting photos.**

## Keep private data out

Don't commit or attach `.dat` backups, RAF files or vault files. They can contain your camera's serial number.

## Pull requests

Keep them small and focused on one change. Add a test for anything that changes camera behaviour.

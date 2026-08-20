# SimVirtualLocation

Easy to use MacOS 11+ application for easy mocking iOS device and simulator location in realtime. Built on top of  [set-simulator-location](https://github.com/MobileNativeFoundation/set-simulator-location) for iOS Simulators and [pymobiledevice3](https://github.com/doronz88/pymobiledevice3). Android support is realized with [SimVirtualLocation](https://github.com/nexron171/android-mock-location-for-development) android app which is fork from [android-mock-location-for-development](https://github.com/amotzte/android-mock-location-for-development).

Posibilities:
- supports both iOS and Android
- set location to current Mac's location
- set location to point on map
- make route between two points and simulate moving with desired speed
- pause and resume a route without starting it over, and change speed while it runs

You can dowload compiled and signed app [here](https://github.com/nexron171/SimVirtualLocation/releases).

## Download this build

Every push to `main` publishes a universal (Apple Silicon + Intel) build to the
[latest release](../../releases/tag/latest).

1. Download and unzip `SimVirtualLocation.zip`, and move the app to `/Applications`.
2. The build is ad-hoc signed rather than notarized, so macOS quarantines it on
   download. Clear that once:

   ```shell
   xattr -dr com.apple.quarantine /Applications/SimVirtualLocation.app
   ```

3. Open it normally from then on.

For iOS devices you still need `pymobiledevice3` installed — see below.

## Keeping a location applied

A point set with **Set to A** / **Set to Coordinate** used to be applied once and never
looked at again. `simulate-location set` holds a DVT channel open and the point outlives
that channel, but only for a grace period — so a point set before a drive could quietly
lapse back to real GPS while the app still looked like it was simulating.

**Keep location applied** (on by default) re-applies the held point every 15 seconds, and
immediately whenever the session holding it ends. The banner across the top of the window
is driven only by confirmed injections:

| Banner | Meaning |
| --- | --- |
| **Location held** (green) | The device confirmed the point, with the time it did so. |
| **Applying location…** (amber) | An attempt is in flight. |
| **LOCATION NOT SET** (red) | The last attempt failed — the device is on its real GPS. |

Red also beeps and bounces the dock icon, since the Mac is usually not being watched. The
held point is remembered across launches, and quitting while a point is held asks first.

The device has the final say: an unplugged cable, a device reboot, or the Mac sleeping
ends a hold and no host-side setting prevents that. The app re-establishes the point as
soon as it can and never reports a hold it has not confirmed.

![App Screen Shot](https://raw.githubusercontent.com/nexron171/SimVirtualLocation/master/assets/screenshot.png)

## FAQ
---
### How to run
If you see an alert with warning that app is corrupted and Apple can not check the developer: try to press and hold `ctrl`, then click on SimVirtualLocation.app and select "Open", release `ctrl`. Now alert should have the "Open" button. Don't forget to copy app from dmg image to any place on your Mac.

### For iOS devices
`python3` and `pymobiledevice3` are should be installed

```shell
brew install python3 && python3 -m pip install -U pymobiledevice3
```

For iOS Device - select device from dropdown and then click on Mound Developer Image. If you see an error that there is no appropriate image - download one from https://github.com/mspvirajpatel/Xcode_Developer_Disk_Images/releases if your iOS for example 16.5.1 and there is only 16.5 - it's ok, just copy and rename it to 16.5.1 and put it inside Xcode at `.../Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/DeviceSupport/`

#### iOS 17 and newer

Leave the **iOS 17+** checkbox ticked (it is on by default) and keep **Connection** on
**Automatic**. Pick your iPhone from the **Device** dropdown and that is the whole setup —
SimVirtualLocation opens the tunnel itself using pymobiledevice3's userspace network stack,
so no Terminal window and no `sudo` are involved. Progress is shown under the dropdown while
the tunnel comes up.

Switch **Connection** to **Manual** only if you would rather use a kernel tunnel, which is
faster for large transfers. Start it yourself, keep it running, and copy the two values it
prints into the RSD Address and RSD Port fields:

```shell
sudo python3 -m pymobiledevice3 remote start-tunnel
```

### If iOS device is unlisted

Try to refresh list and if it does not help - go to Settings / Developer on iPhone and click Clear trusted computers. Replug cable and press refresh. If it still not in list - go to Xcode / Devices and simulators and check your device, there are should not be any yellow messages. If it has - make all that it requires.

---
### For Android
1. Check if debugging over USB is enabled
1. Specify ADB path (for example `/User/dev/android/tools/adb`)
1. Specify your device id (type `adb devices` in the terminal to see id)
1. Setup helper app by clicking `Install Helper App` and open it on the phone
1. Grant permission to mock location - go to Developer settings and find `Application for mocking locations` or something similar and choose SimVirtualLocation
1. Keep SimVirtualLocation running in background while mocking



# SimVirtualLocation

Easy to use MacOS 11+ application for easy mocking iOS device and simulator location in realtime. Built on top of  [set-simulator-location](https://github.com/MobileNativeFoundation/set-simulator-location) for iOS Simulators and [pymobiledevice3](https://github.com/doronz88/pymobiledevice3). Android support is realized with [SimVirtualLocation](https://github.com/nexron171/android-mock-location-for-development) android app which is fork from [android-mock-location-for-development](https://github.com/amotzte/android-mock-location-for-development).

Posibilities:
- supports both iOS and Android
- set location to current Mac's location
- set location to point on map
- make route between two points and simulate moving with desired speed
- keeps the point applied and tells you the moment it stops working

## Keeping a location applied

Every transport used to mock a location is one-shot or tied to a live session: the
developer-disk-image service drops the simulation when its connection closes, the
iOS 17+ DVT channel dies with the `pymobiledevice3` process behind it, and the
simulator notification is overridden by anything else that sets a location. Setting a
point once is therefore not enough — it can revert to real GPS on its own.

SimVirtualLocation treats a set point as something it has to keep defending:

- **Re-applies it continuously.** `Keep location applied` re-pushes the point every 5s
  by default (2s–30s). On iOS 17+ a live session is the hold, so it is verified rather
  than relaunched.
- **Reacts the instant a session dies.** The helper process is watched, and its death
  triggers an immediate re-apply — not a wait for the next tick.
- **Never breaks before it makes.** A session holding the old point is retired only
  after the replacement has been accepted, so changing target, transport, or point
  does not open a window on real GPS.
- **Tracks the iOS 17+ tunnel.** With `sudo pymobiledevice3 remote tunneld` running and
  `Track tunnel automatically` on, the app reads the current RSD address itself, so a
  tunnel that restarts recovers without you pasting anything.
- **Survives its own restart.** The held point is persisted; if the app crashes or the
  Mac reboots, it resumes the hold on next launch.
- **Refuses to quietly go away.** Quitting or closing the window while a point is held
  asks first, and the Mac is kept from idle-sleeping.

The banner at the top of the window is driven only by confirmed injections:

| Banner | Meaning |
| --- | --- |
| **Location held** (green) | The point was confirmed applied, with the time of the last confirmation. |
| **Applied once — NOT being kept alive** (amber) | `Keep location applied` is off, so nothing is verifying the point. |
| **Location may have dropped** (amber) | An attempt failed; the app is retrying and shows why. |
| **LOCATION NOT SET** (red) | Three attempts in a row failed. The device is on its real GPS. |

Anything other than green also beeps and bounces the dock icon, so a hold that breaks
while you are away from the Mac does not go unnoticed. Common causes are named
directly in the banner — a locked iPhone, a tunnel that needs restarting, an unplugged
cable, a simulator that shut down.

### What the app cannot prevent

The device, not the Mac, owns the final decision, and some events end a hold no matter
what this app does. In each case the app re-establishes the point as soon as it
physically can, and says so loudly in the meantime:

- the USB cable is unplugged, or the iPhone is locked in a way that blocks the service
- the iPhone reboots, or Developer Mode / the mounted disk image goes away
- the Mac sleeps (closing the lid), loses power, or is force-quit
- no tunnel is running at all on iOS 17+, and none can be started without `sudo`

For an unattended run, keep the Mac awake and plugged in, keep `tunneld` running, and
watch the banner — it is the only honest signal of whether the point is still applied.

You can dowload compiled and signed app [here](https://github.com/nexron171/SimVirtualLocation/releases).

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

For iOS 17+ select checkbox iOS 17+ and provide RSD Address and RSD Port from command:
```shell
sudo python3 -m pymobiledevice3 remote start-tunnel
```
It needs sudo, because it will instantiate low level connection between Mac and iPhone. Keep this command running while mocking location for iOS 17+.

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

### Contributors

<!-- readme: collaborators,contributors -start -->
<table>
    <tr>
        <td align="center">
            <a href="https://github.com/nexron171">
                <img src="https://avatars.githubusercontent.com/u/6318346?v=4" width="100;" alt="nexron171"/>
                <br />
                <sub><b>Sergey Shirnin</b></sub>
            </a>
        </td>
        <td align="center">
            <a href="https://github.com/sk-chanch">
                <img src="https://avatars.githubusercontent.com/u/22313319?v=4" width="100;" alt="sk-chanch"/>
                <br />
                <sub><b>Skipp</b></sub>
            </a>
        </td>
        <td align="center">
            <a href="https://github.com/styresdc">
                <img src="https://avatars.githubusercontent.com/u/10870930?v=4" width="100;" alt="styresdc"/>
                <br />
                <sub><b>styresdc</b></sub>
            </a>
        </td>
        <td align="center">
            <a href="https://github.com/natiginfo">
                <img src="https://avatars.githubusercontent.com/u/3982965?v=4" width="100;" alt="styresdc"/>
                <br />
                <sub><b>natiginfo</b></sub>
            </a>
        </td>
        <td align="center">
            <a href="https://github.com/resuly">
                <img src="https://avatars.githubusercontent.com/u/3870826?v=4" width="100;" alt="styresdc"/>
                <br />
                <sub><b>resuly</b></sub>
            </a>
        </td>
    </tr>
</table>
<!-- readme: collaborators,contributors -end -->

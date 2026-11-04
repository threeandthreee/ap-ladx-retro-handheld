# AP LADX for Retro Handhelds

Do some Link's Awakening DX Archipelago multiworlding on your fake game boy!

This will patch your rom and run the AP LADX client in the background for you. It can also generate solo games right on the handheld. From there you just load it up in Retroarch.

I would think this can run on any arm64 retro handheld with the right configuration, but I have only packaged it for [MuOS](https://muos.dev) (because that's what I use) and I've only tested it on an Anbernic RG34xx and RG35xx (because that's what I have).

This relies on the presence of a terminal application with an on-screen keyboard for all input and output, so that is also a requirement as some firmwares ship without one. MuOS Andromeda has one, the previous version did not.

If you can find me packaging docs for your firmware, can locate a terminal application, and are willing to do some testing, I can probably set up a package for your firmware.


## Installation

### MuOS Andromeda

Specifically Andromeda because the previous release doesn't ship with a terminal.

1. Download `APLADX.muxapp` from the latest release.
2. Put it in `MUOS/ARCHIVE/` on your device.
3. On your device, open it in **Archive Manager** to install it.
4. Launch it from **Applications** so that it can unpack Archipelago and set up some directories.
5. Your `APLADX` directory can be found at `MUOS/Applications/APLADX`.


## Setup

### Base ROM

You will need to provide your English 1.0 LADX Rom file. It will look for it in your GBC roms directory, as well as in the `APLADX` application directory.

### LADX Beta (optional)

1. Download `ladx_beta.apworld` from [here](https://github.com/threeandthreee/Archipelago/releases).
2. Put it in the `APLADX` application directory on your device.

It will automatically be moved to where it belongs next time you launch the app. You can update the apworld this way as well.


## Usage

The interface will list options like `(c)ontinue`, which you can select by typing the letter in parenthesis and pressing enter (usually start). You might need to press a button to bring up your keyboard, on MuOS its *select*. If an option is capitalized, such as `(Q)uit`, that indicates the default option, which will be selected by pressing enter with nothing typed.


### Multiworlds

Put patch files into `APLADX/patches` on your device. You might consider giving them more friendly names before doing so. When you launch the application you can select the patch file to patch the rom and launch the client. **Do not delete patch files until you are done with the slot.** When the patch file is found missing, the rom and its save files will automatically be removed on next launch.

Once the client is running, launch your patched rom in **Retroarch**. They will be in a `APLADX` subdirectory of your GBC roms directory. In MuOS, make sure its **Retroarch** not **Pickles**, and using **Gambatte** or **Sameboy**. Make sure network commands are enabled.

You can run the **APLADX** application again to close the client, or it will close automatically if you put your device to sleep.


### Solo seeds

Put yamls into `APLADX/solo_yamls` on your device. Launch the **APLADX** application and select **(s)olo**. The rom will end up in the `APLADX` subdirectory of your GBC roms directory, named to match the name of your yaml.


## Configuration

Device specific paths can be edited in `APLADX/platform.conf`. On MuOS you'll need to edit your `BASE_ROM_DIRECTORY` if your roms are on the second SD card. You'll need to adjust the save paths if you use Sameboy instead of Gambatte.

If you don't want this managing your save files, just clear out `SAVEFILE_DIRECTORY` and `SAVESTATE_DIRECTORY`.

You can edit `APLADX/.data/Archipelago/host.yaml` if you want to set up a gfxmod file or option overrides.


## Why just LADX?

I think its the only Archipelago implementation fit for handheld that runs on Retroarch? Someday in the future if we have both [PolyEmuClient](https://github.com/ArchipelagoMW/Archipelago/pull/4659) and [Retroarch Lua Scripting](https://github.com/libretro/RetroArch/pull/18789), it might be possible to play more games this way.


## AI Use

The shell scripts were almost entirely written by Claude, because lazy and I don't have much experience with shell scripting. I was very precise in my specifications, reviewed all output, learned a little something, and dare I say gained some appreciation for the language. I did do a lot of testing as well.
# Palworld mods by Falor

Source of the Palworld 1.0 mods, copied out of the game folder on 2026-11-24.
All Lua mods run on UE4SS; the settings pages use the Mod Options Framework.

## What is where

| Folder | Content |
| --- | --- |
| `workshop/FalorQoLPack` | Falor's QoL Pack 1.0.1 exactly as published on the Steam Workshop (item 3841959506): 12 UE4SS Lua mods and the PalSchema tweaks |
| `workshop/PassiveTransfer` | Passive Transfer as published on the Steam Workshop (item 3841945149) |
| `workshop/*_workshop_description.txt` | Workshop page texts |
| `local-mods/CompleteAllQuests` | Complete All Quests (not published): finishes main and side quests with their rewards, two separate switches |
| `local-mods/CoopPlus` | Shares unlocked fast travel points inside a guild (not published) |
| `local-mods/AutoLoadWorld` | Development helper: loads a given world at start |
| `local-mods/DevConsole`, `local-mods/DevDump` | Development helpers, disabled in normal play |
| `local-mods/BaseWorkerMultiplier` | Paused experiment, disabled |
| `tools/release-scripts` | Scripts used while publishing to the Workshop |
| `my-settings` | The author's own mod list and Mod Options values |

## Installing a mod from here

Copy a mod folder into `Palworld\Mods\NativeMods\UE4SS\Mods\`. The mod needs
UE4SS Experimental (Palworld), and the Mod Options Framework for its settings
page. The PalSchema part of the pack goes into the PalSchema `mods` folder.

`PalModOptionsClient.lua` and `pmo_json.lua` belong to the Mod Options
Framework (MIT, license file next to them).

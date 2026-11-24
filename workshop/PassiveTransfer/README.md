# Passive Transfer

Move one passive skill from a Pal in your party to another Pal in your party.
The giver loses the passive, so nothing is duplicated.

- Press **F5** in a world to open the panel (the key can be changed).
- Pick the giver, the passive, then the receiver, and press **Transfer**.
- If the receiver already has 4 passives, you pick one of them and it goes
  back to the giver (a swap).
- Every step is read back from the game; if a step fails, the earlier steps
  are undone.
- Panel language: English or Turkish (follows the game language, or pick one).

## Requirements (Steam Workshop)

| Mod | Workshop ID | Why |
|---|---|---|
| UE4SS Experimental (Palworld) | 3625223587 | runs the Lua script |
| Mod Options Framework | 3771664251 | settings page (Esc > Mod Options) |

PalSchema is **not** needed.

Install all three from the Steam Workshop only. Do not also keep a manually
installed UE4SS (for example a `dwmapi.dll` / `ue4ss` folder under
`Pal\Binaries\Win64`): two UE4SS copies load at once and the game crashes at
startup.

## Install

1. Subscribe to this mod and to the two requirements.
2. Start Palworld, open **Options > Mod Management**, enable all three, save.
   The game restarts.
3. Load a world you host and press **F5**.

## Settings

Esc > Mod Options > Passive Transfer

- Enabled
- Open / close key (default F5; a key change applies after restarting the game)
- Panel language (Auto / English / Türkçe)

## Limits - please read

- **World host only.** It works in single player and for the host of a co-op
  world. A guest who joins someone else's world gets the message "Only the
  world host can use this." Dedicated servers are not supported.
- Both Pals must be in your party (the 5 party slots).
- Every passive can be moved, including rare ones. There is no cost and no
  cooldown.
- Changes are written into the save. Removing the mod does not undo transfers
  you already made. Back up your save first if you are unsure.

## Tested

Palworld 1.0 on Steam (Windows), as world host: transfer, swap with a full
receiver, and the saved result after a restart.

Not tested: dedicated servers, Game Pass.

## Credits

- Settings page: Mod Options Framework by Elv (MIT license). Its two SDK
  files `PalModOptionsClient.lua` and `pmo_json.lua` are included as its
  documentation asks; the license text is next to them.
- UE4SS Experimental (Palworld) by Oak.

---

## Türkçe

Takımındaki bir Pal'ın pasifini takımındaki başka bir Pal'a taşır. Veren Pal
o pasifi kaybeder, yani hiçbir şey çoğalmaz.

- Dünyadayken **F5** paneli açar (tuş değiştirilebilir).
- Vereni, pasifi ve alanı seç, **Aktar**'a bas.
- Alan Pal'da zaten 4 pasif varsa onlardan birini seçersin; o pasif verene
  geçer (takas).
- Yalnızca dünyanın host'unda çalışır. Başkasının dünyasına katılan oyuncu
  kullanamaz. Dedicated server desteklenmez.
- İki Pal da takımında (5 takım yuvası) olmalı.
- Değişiklikler kayda yazılır; modu kaldırmak yapılan aktarımları geri almaz.

Gerekenler (yalnızca Steam Atölyesi'nden): UE4SS Experimental (Palworld) ve
Mod Options Framework. Elle kurulmuş ikinci bir UE4SS bırakma, oyun açılışta
çöker.

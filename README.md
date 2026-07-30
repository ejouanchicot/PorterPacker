# PorterPacker

A Windower 4 addon for Final Fantasy XI that operates the Porter Moogle for you.

## What problem does this solve?

Storage slips let you park hundreds of pieces of gear with a Porter Moogle
instead of burning inventory space. The catch is the interface: to swap your
storage around you have to walk through the Moogle's menus and confirm every
single item, one at a time. Doing that for a full job's worth of gear takes a
long, dull while.

PorterPacker drives those menus for you. You stand next to a Porter Moogle,
type one command, and it packs away the gear you're not using and pulls out the
gear you need.

```
//po
```

That's the whole thing. It stores everything for the jobs you're not on and
retrieves everything for the job you're currently playing.

---

## Before you start

You need:

- **Windower 4** installed and working.
- **Storage slips** you've already obtained in game. PorterPacker uses slips you
  own — it does not get them for you.
- Your slips kept in a bag the addon can find. **By default it looks in your
  satchel.** If you keep them somewhere else, see [Configuration](#configuration).

The `slips` and `resources` libraries the addon depends on ship with Windower,
so there is nothing extra to download.

**Expect to end up naked.** Every pack or unpack command undresses you first, and
that is not optional: the Porter Moogle cannot take a piece you are wearing, so
gear left equipped is gear the addon cannot see. If GearSwap is loaded it is used
to do the undressing and its slots are locked for the duration, then released when
the run finishes. Should a run ever die halfway and leave you unable to change
gear, `//po reset` hands the slots back.

---

## Installation

### The easy way — download the release

1. Go to the [latest release](https://github.com/ejouanchicot/PorterPacker/releases/latest).
2. Download `PorterPacker-2.1.0.zip`.
3. Extract it into your Windower addons folder.

You should end up with this — the folder must be named `PorterPacker`:

```text
Windower4/addons/PorterPacker/
    PorterPacker.lua
    README.md
    data/
    lib/
    messages.lua
```

The addons folder is usually at `C:\Program Files (x86)\Windower4\addons`.

### The git way

If you have git and want to pull updates easily:

```sh
cd "C:/Program Files (x86)/Windower4/addons"
git clone https://github.com/ejouanchicot/PorterPacker.git
```

### Load it in game

Log in, then type:

```text
//lua load porterpacker
```

You should see the addon announce itself in your chat log. To load it
automatically every time you launch, add this line to
`Windower4/scripts/init.txt`:

```text
lua load porterpacker
```

---

## Where are the Porter Moogles?

You have to be standing next to one. Here's where they live:

| Area | Coordinates |
| --- | --- |
| Lower Jeuno | I-6 |
| Northern San d'Oria | K-8 |
| Bastok Markets | I-9 |
| Port Windurst | L-6 |
| Western Adoulin | H-11 |
| Aht Urhgan Whitegate | I-11 |
| Nashmau | H-6 |
| Tavnazian Safehold | F-8 |
| Mog Garden | — |
| Selbina | I-9 |
| Mhaura | I-8 |
| Kazham | H-9 |
| Rabao | G-8 |
| Norg | G-7 |
| Southern San d'Oria [S] | M-5 |
| Bastok Markets [S] | H-7 |
| Windurst Waters [S] | L-10 |

---

## Your first run

Do this once to check everything works.

**1. Stand next to a Porter Moogle.** If you're too far away the addon will
tell you it "is not in range".

**2. Stand still.** Don't move, don't be in combat, don't be sitting. The addon
refuses to start unless your character is idle, because moving mid-run breaks
the menu sequence.

**3. Make some inventory room.** The addon holds storage slips in your
inventory while it works. It only fetches the slips your command actually
needs — usually a handful, not all 33 — so a swap does not require an empty
bag. If it still cannot fit them it will say exactly how many slots to free.

**4. See where you stand:**

```text
//po s
```

This shows you what's currently stored versus what's out, without changing
anything. Nothing is moved — it's safe to run any time.

**5. Now do a real swap:**

```text
//po
```

Sit back. It will work through the menus, and it can take a while — that's
normal, it's doing what you'd otherwise do by hand. **Don't move or press
anything while it runs.**

> **Nothing happened?** You probably haven't set up your gear lists yet. The
> addon needs to know which items belong to which job. See the next section.

---

## Setting up your gear lists

This is the one part that takes effort, and you only do it once per job.

PorterPacker reads plain text files that say which items belong to which job.
They live in a folder named after your character:

```text
data/
  YourCharacterName/
    Active/
      WAR.lua        <- jobs you actually play
      THF.lua
    Inactive/
      SMN.lua        <- jobs you keep stored and don't play
    config.lua       <- optional settings
```

**The folder name must match your character's name exactly.** A character
called Zaphod loads `data/Zaphod/Active/BLM.lua`.

**Active vs Inactive** is just a way to keep jobs you never play out of the way.
`//po fetch` only unpacks Active jobs; `//po all` packs both.

### Option A — let the addon write the lists for you (easiest)

Stand at a Porter Moogle with your gear out, and run:

```text
//po export all
```

This reads your live inventory and writes one file per bag into `data/`. Rename
those files to job codes (`WAR.lua`, `THF.lua`, ...) and move them into
`data/YourCharacterName/Active/`. Then trim anything that doesn't belong.

### Option B — copy an example and edit it

Two complete, working profiles ship with the addon:

| Profile | What it shows |
| --- | --- |
| `data/Player1/` | A main character: 8 active jobs, 15 stored, plus a `config.lua` that skips a craft wardrobe |
| `data/Player2/` | An alt: 3 active jobs, everything else parked in `Inactive/` |

These are **real, populated gear lists**, not empty placeholders — actual item
names, real item counts. Open `data/Player1/Active/WAR.lua` to see what a
finished file looks like.

Copy one and rename it:

```sh
cp -r data/Player1 data/YourCharacterName
```

Then edit the job files to match your own gear.

### Option C — start from blank templates

`data/Default/` has bare per-job files if you'd rather build up from nothing
than prune someone else's list.

### What goes in a list file

The simple form is just a list of item names:

```lua
return {
    "Sakpata's Helm",
    "Sakpata's Plate",
    "Moonlight Ring",
}
```

The advanced form splits it in two, which is worth understanding:

```lua
return {
    pack   = { ... },  -- everything this job could ever store
    unpack = { ... },  -- only what you actually need pulled out
}
```

`pack` can be wide — throw everything in. `unpack` should be narrow, listing
only the pieces your gear sets really use. This keeps swaps fast: you store a
lot, but you only retrieve what you'll wear.

> **Item names must match the game exactly**, including FFXI's abbreviations —
> `"Pumm. Cuisses"`, not `"Pummeler's Cuisses"`. This is the most common reason
> an item silently gets skipped. If you're unsure of a name, use
> `//po export all` and copy it from the generated file.

---

## Everyday use

Once your lists exist, this is all you need:

| You want to... | Type |
| --- | --- |
| Switch storage to the job you're on | `//po` |
| Switch storage to a specific job | `//po WAR` |
| Just put this job away | `//po p WAR` |
| Just get this job out | `//po u WAR` |
| Put **everything** away | `//po all` |
| Get all your active jobs out | `//po fetch` |
| Check what's stored | `//po s` |

---

## Full command reference

All three prefixes do the same thing: `//porterpacker`, `//packer`, `//po`.

### Main commands

| Command | Effect |
| --- | --- |
| `//po` | Swap to your current job — pack everything else, unpack this one |
| `//po <JOB>` | Swap to `<JOB>` |
| `//po swap [JOB]` | Same as above (defaults to your current job) |
| `//po u [JOB]` | Unpack only — alias `unpack` |
| `//po p [JOB]` | Pack only — alias `pack` |
| `//po all` | Pack every job, Active and Inactive — alias `packall` |
| `//po fetch` | Unpack all Active jobs — alias `unpackall` |
| `//po fetch inactive` | Unpack all Inactive jobs |
| `//po s [scope]` | Status: what's stored vs out — alias `status`, `info` |

For `//po s`, `scope` can be `active` (the default), `inactive`, `all`, or a job
code like `WAR`.

### Utilities

| Command | Effect |
| --- | --- |
| `//po help` or `//po ?` | Show the command list in game |
| `//po reset` or `//po unstuck` | Force-reset if the addon gets stuck |
| `//po slips` or `//po rs` | Put stray slips back in your satchel |
| `//po export [name]` | Export storable inventory to `data/<name>.lua` |
| `//po export all` | Export every bag, one file each |
| `//po debug on` / `off` | Write packet logs to `debug.log` |

---

## Configuration

Optional. Create `data/YourCharacterName/config.lua`:

```lua
return {
    ignore_bags   = { 15 },  -- bags PorterPacker must never touch
    slip_home_bag = 5,       -- where your storage slips live
}
```

**`ignore_bags`** protects bags from being touched. The usual reason is a
wardrobe reserved for crafting or fishing gear that you never want packed away.

**`slip_home_bag`** tells the addon where your slips are kept. Default is `5`
(satchel).

Bag IDs:

| ID | Bag | ID | Bag |
| --- | --- | --- | --- |
| 0 | Inventory | 12 | Wardrobe 4 |
| 5 | Satchel | 13 | Wardrobe 5 |
| 6 | Sack | 14 | Wardrobe 6 |
| 7 | Case | 15 | Wardrobe 7 |
| 8 | Wardrobe 1 | 16 | Wardrobe 8 |
| 10 | Wardrobe 2 | | |
| 11 | Wardrobe 3 | | |

---

## Troubleshooting

**"... is not in range"**
You're too far from the Porter Moogle. Walk closer.

**"Not enough inventory space: N of M needed slip(s) could not be gathered"**
The addon holds the storage slips in your inventory while it works. It only
fetches the ones the command actually needs, so this means you are genuinely
short — free the number of slots it names and run the command again.

**It says it's busy and won't start**
Your character isn't idle — you're moving, fighting, resting, or a previous run
hasn't finished. Stand still and wait. If it stays stuck, use `//po reset`.

**"No data files found in data/YourName/Active/..."**
Your gear lists don't exist yet. See
[Setting up your gear lists](#setting-up-your-gear-lists).

**"Network deadlock detected"**
The FFXI client's packet queue is jammed. Zone to a different area to clear it,
then retry.

**"Already running: an operation is in progress"**
A previous command is still working — a full `//po all` takes minutes. Let it
finish, or stop it with `//po reset`.

**I can't change gear after a run**
A run that died partway can leave GearSwap's slots locked. `//po reset` releases
them.

**It stopped partway through**
Run `//po reset`, then `//po slips` to return any slips left loose in your
inventory. Then try again.

**Still broken**
Turn on logging with `//po debug on`, reproduce the problem, and check
`debug.log` in the addon folder — or open an
[issue](https://github.com/ejouanchicot/PorterPacker/issues) and include it.

---

## A word of caution

This addon moves your gear around automatically. Before your first big run
(`//po all` in particular), it's worth doing a small single-job swap first to
confirm everything behaves as you expect. Don't move or interact with anything
while it's running.

---

## Credits

Refactor by **ejouanchicot** — full rewrite: modular `lib/` split, per-character
data folders, bulk pack/unpack, status panel, debug logger, and defensive
inventory handling. Current maintainer.

Original packet handling — the porter dialog state machine, trade injection and
slip parsing — by **Ivaar**, with subsequent modifications by **Gimlic** and
**Siyual** before this refactor.

## License

[BSD 3-Clause](LICENSE). Portions derived from the original implementation
remain the copyright of their respective authors — see [NOTICE](NOTICE).

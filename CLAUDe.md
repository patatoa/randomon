# CLAUDE.md

Guidance for working in this repository. This is a **fork of Pokémon Showdown** that adds
a custom **random-team battle format**: every player is handed a randomly assigned team each
match, drawn from a pool tuned so that every member is *potentially viable*.

> **Names below (`randomroster`, "Random Roster") are placeholders — rename them to the real
> project name before shipping.** They appear as the mod id, the generator folder, and the
> format id, so rename consistently in all three places.

---

## 1. Project goal

Two phases, built on the same seam so phase 2 slots in without a rewrite:

- **Phase 1 — curated real Pokémon.** Restrict the random-battle pool to a hand-picked subset
  of real Pokémon and reuse Showdown's existing hand-tuned movesets. Balance work =
  *choosing the roster*. This ships fast.
- **Phase 2 — procedurally generated custom Pokémon.** Mint custom species (stats / typing /
  ability choice) and generate viable sets for them. Balance is validated *empirically* via
  headless simulation rather than asserted by hand.

**The seam that makes both work:** the generator builds its entire species pool from the keys
of one object — `randomSets` (see §5). Phase 1 populates that object from a curated JSON file.
Phase 2 populates the same object from a generator. Everything downstream (movesets, items,
EVs, battle plumbing) is inherited and untouched.

---

## 2. Prerequisites

- **Node.js v18+** (repo states v16+ minimum; use a current LTS). `npm i -g n && n latest`
  upgrades in place if your distro ships an old Node.
- **git**
- No database or external services needed for local development.

---

## 3. Setup

### Server (this repo — the engine + simulator, MIT licensed)

```bash
git clone https://github.com/smogon/pokemon-showdown
cd pokemon-showdown
cp config/config-example.js config/config.js   # required before first run
./pokemon-showdown                             # builds TypeScript, then serves on :8000
```

Visit `http://localhost:8000`. The server auto-compiles on start; use `node build` to compile
without starting the server.

### Client (optional — the web UI, AGPLv3 licensed)

Only needed if you want to self-host the front end instead of embedding `psim.us`. Not
required for developing or testing the format.

```bash
git clone https://github.com/smogon/pokemon-showdown-client
```

> **License note:** the server is MIT (permissive). The client is **AGPLv3** (copyleft — a
> modified client run as a network service must publish its source). Keep the two repos'
> obligations straight if you distribute. Separately: **Nintendo/Game Freak own the Pokémon
> names, sprites, and audio.** The engine and data structures are fine to fork; the official
> art/audio assets are not redistributable. Custom (phase-2) species must use original assets.

---

## 4. Repository map

**Do not edit `sim/`.** That's the battle engine. This project only adds *data* and a *format*.

| Path | What it is | Touch? |
|------|-----------|--------|
| `sim/` | Battle engine, RNG, protocol, `Teams` API | ❌ read-only reference |
| `data/` | Base Pokédex, moves, abilities, items, learnsets | ⚠️ only via a mod (§6) |
| `data/random-battles/gen9/teams.ts` | The Gen 9 random team generator (`RandomTeams` class) | ❌ read as reference |
| `data/random-battles/gen9/sets.json` | Hand-tuned per-mon set data; **pool = its keys** | ✅ copy subset from |
| `data/random-battles/sharedpower/teams.ts` | **Canonical example of a variant random format** — copy this pattern | ❌ reference |
| `data/mods/<modid>/` | Custom Dex data (custom species live here in phase 2) | ✅ our code |
| `data/random-battles/<modid>/` | Our generator + curated `sets.json` | ✅ our code |
| `config/custom-formats.ts` | Where we register our format | ✅ our code |
| `config/config.js` | Local server config (gitignored; from `config-example.js`) | ✅ local only |

Reference docs in-repo: `ARCHITECTURE.md`, `COMMANDLINE.md`, `sim/README.md`,
`server/README.md`.

---

## 5. How a variant random format is wired (verified)

A random format is a config object with `team: 'random'` and a `mod`. The generator is
resolved from `data/random-battles/<mod>/teams.ts`, which extends the Gen 9 generator. The
`sharedpower` variant is the whole pattern in three lines:

```ts
// data/random-battles/sharedpower/teams.ts
import RandomTeams from '../gen9/teams';
export class RandomSharedPowerTeams extends RandomTeams {}
export default RandomSharedPowerTeams;
```

Inside `data/random-battles/gen9/teams.ts` the key facts:

- `randomSets = require('./sets.json')` — the per-species set data.
- `randomTeam()` (entry point) builds `pokemonList = Object.keys(this.randomSets)` and passes
  it to `getPokemonPool(...)`.

**Therefore the species pool is exactly the keys of `randomSets`.** Override that object and
you control the pool *and* inherit viable sets for free. This is our single seam.

---

## 6. Phase 1 — curated real Pokémon (do this first)

1. **Curate the roster.** Pick species that already exist in `data/random-battles/gen9/sets.json`
   (so they come with hand-tuned sets). Copy just those entries into a new file:
   `data/random-battles/<modid>/sets.json`.

2. **Create the generator** at `data/random-battles/<modid>/teams.ts`, overriding `randomSets`
   to load the curated file. Because the pool derives from its keys, this both restricts the
   pool and supplies the sets:

   ```ts
   // data/random-battles/randomroster/teams.ts
   import RandomTeams from '../gen9/teams';

   export class RandomRosterTeams extends RandomTeams {
     // Pool = keys of this object; sets come from the same file. One override does both.
     randomSets: { [species: string]: any } = require('./sets.json');
   }
   export default RandomRosterTeams;
   ```

3. **Create the mod folder** `data/mods/<modid>/`. For phase 1 it can inherit Gen 9 unchanged
   (no species edits yet). Mirror the structure `sharedpower` uses; confirm resolution against
   `sim/teams.ts` (`Teams.getGenerator`) if anything doesn't load.

4. **Register the format** in `config/custom-formats.ts`:

   ```ts
   export const Formats: import('../sim/dex-formats').FormatList = [
     { section: "Custom Formats" },
     {
       name: "[Gen 9] Random Roster",
       desc: "Each player gets a randomly assigned team from a curated, balanced pool.",
       mod: 'randomroster',
       team: 'random',
       ruleset: ['Obtainable', 'Species Clause', 'HP Percentage Mod', 'Cancel Mod', 'Sleep Clause Mod'],
     },
   ];
   ```

5. **Smoke-test generation** (fastest iteration loop — no full server needed):

   ```bash
   ./pokemon-showdown generate-team gen9randomroster
   ```

   Run it repeatedly; confirm every generated team stays inside the curated roster and that
   sets look sane. Then start the server and battle the format in the UI.

**Definition of done for Phase 1:** two players can queue the format and each receives a random
6-mon team drawn only from the curated pool, with coherent movesets/items.

---

## 7. Phase 2 — procedural custom Pokémon (later)

Same seam, harder inputs. Custom species have **no** `sets.json` entry, so `randomSets` must be
*generated* instead of copied.

1. **Generate species data** into `data/mods/<modid>/pokedex.ts` (+ `learnsets.ts` etc. only if
   customizing movepools). Principles that keep viability tractable:
   - **Generate species, not moves.** Assign real moves from the existing move DB — never
     invent move mechanics. Guarantee at least STAB + adequate coverage per set.
   - **Role-first stat budgeting.** Pick an archetype (fast physical attacker / bulky pivot /
     setup sweeper / wall), then distribute a fixed stat budget to fit it. Don't roll six raw
     numbers and hope.
   - **Whitelist abilities into power tiers.** Gate strong abilities behind stat penalties.
     (Showdown deliberately abandoned algorithmic ability rating — curate, don't compute.)

2. **Generate sets** for each species — either author `randomSets` entries at species-creation
   time, or override `randomSet()` in the subclass to build sets algorithmically. Validate the
   generator against *real* mons first (where hand-tuned sets exist as ground truth) before
   trusting it on generated ones.

3. **Empirical viability loop.** Close the loop by measurement, not assertion. The engine runs
   headless (`sim/` `BattleStream`; see `COMMANDLINE.md` and `./pokemon-showdown simulate-battle`).
   Precedent: the official randbats set data is derived by simulating 100k teams and aggregating.
   Pipeline: generate candidate mons → round-robin sim battles with a simple policy → keep the
   ones whose win rate lands in a target band → prune strictly dominated mons. That is
   "potentially viable" *measured*.

4. **Decide on Tera.** Gen 9 sets carry a Tera type; it's an enormous balance lever. For a
   custom pool, constrain or disable it rather than inheriting the chaos.

---

## 8. Commands cheat sheet

```bash
cp config/config-example.js config/config.js         # one-time, before first run
./pokemon-showdown                                   # build + serve on :8000
./pokemon-showdown 8000                              # serve on an explicit port
node build                                            # compile TS without starting the server
./pokemon-showdown generate-team gen9randomroster    # print one packed team (fast test loop)
./pokemon-showdown simulate-battle                   # headless battle from stdin protocol
npm test                                              # run the test suite
```

---

## 9. Conventions & gotchas

- **Gen 9 only.** The generator is per-generation — each gen is a separate `teams.ts`.
  Supporting several multiplies the work for no payoff. Pick Gen 9 and stay there.
- **Never edit `sim/`.** All changes are data + a format. If a change seems to require touching
  the engine, reconsider the approach.
- **Curate within the existing randbats pool in Phase 1.** A mon only gets free hand-tuned sets
  if it already has a `sets.json` entry. Picking outside that pool means authoring sets by hand.
- **Rename the placeholders** (`randomroster`, "Random Roster") consistently: mod id, generator
  folder, and format id must match.
- **TypeScript**, Showdown's existing style; run `npm test` and lint before committing.
- **Assets:** never commit Nintendo/Game Freak sprites or audio. Phase-2 species need original
  assets.
- **`config/config.js` is local-only** (gitignored). Don't commit secrets.

---

## 10. References

- Server repo: https://github.com/smogon/pokemon-showdown (MIT)
- Client repo: https://github.com/smogon/pokemon-showdown-client (AGPLv3)
- In-repo: `ARCHITECTURE.md`, `COMMANDLINE.md`, `sim/README.md`, `server/README.md`
- Random Battles explained (Smogon): thread "Questions about how Random Battles formats work?"
- Aggregated randbats set data / stats: https://pkmn.github.io/randbats/
- Embeddable engine repackage (optional, for building a standalone app): `@pkmn/sim`

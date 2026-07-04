#!/usr/bin/env bash
# Download sprites, data files, and other binary assets needed for the self-hosted client.
# Run from the repo root: bash scripts/download-assets.sh
# Safe to re-run: existing files are skipped.

set -e

CDN="https://play.pokemonshowdown.com"
CLIENT="client/play.pokemonshowdown.com"

# Pool sprite IDs (generated from data/random-battles/randomon/sets.json via Dex.spriteid)
POOL_SPRITES=(
  venusaur charizard blastoise arbok pikachu raichu raichu-alola sandslash sandslash-alola
  clefable ninetales ninetales-alola wigglytuff vileplume venomoth dugtrio dugtrio-alola
  persian persian-alola golduck annihilape arcanine arcanine-hisui poliwrath victreebel
  tentacruel golem golem-alola slowbro slowbro-galar dodrio dewgong muk muk-alola cloyster
  gengar hypno electrode electrode-hisui exeggutor exeggutor-alola hitmonlee hitmonchan
  weezing weezing-galar rhydon scyther tauros tauros-paldeacombat tauros-paldeablaze
  tauros-paldeaaqua gyarados lapras ditto vaporeon jolteon flareon snorlax articuno
  articuno-galar zapdos zapdos-galar moltres moltres-galar dragonite mew meganium typhlosion
  typhlosion-hisui feraligatr furret noctowl ariados lanturn ampharos bellossom azumarill
  sudowoodo politoed jumpluff sunflora quagsire clodsire espeon umbreon slowking slowking-galar
  misdreavus girafarig forretress dunsparce granbull qwilfish qwilfish-hisui overqwil scizor
  heracross ursaring magcargo piloswine delibird skarmory houndoom kingdra donphan porygon2
  smeargle hitmontop raikou entei suicune tyranitar sceptile blaziken swampert mightyena
  ludicolo shiftry pelipper gardevoir masquerain breloom vigoroth hariyama sableye medicham
  plusle minun volbeat illumise swalot camerupt torkoal grumpig flygon cacturne altaria
  zangoose seviper whiscash crawdaunt milotic banette tropius chimecho glalie luvdisc salamence
  metagross regirock regice registeel latias latios jirachi deoxys deoxys-attack deoxys-defense
  deoxys-speed torterra infernape empoleon staraptor kricketune luxray rampardos bastiodon
  vespiquen pachirisu floatzel gastrodon ambipom drifblim mismagius honchkrow skuntank bronzong
  spiritomb garchomp lucario hippowdon toxicroak lumineon abomasnow weavile sneasler magnezone
  rhyperior electivire magmortar yanmega leafeon glaceon gliscor mamoswine porygonz gallade
  probopass dusknoir froslass rotom rotom-wash rotom-heat rotom-frost rotom-fan rotom-mow
  uxie mesprit azelf heatran cresselia phione manaphy darkrai shaymin shaymin-sky serperior
  emboar samurott samurott-hisui zebstrika excadrill gurdurr conkeldurr leavanny whimsicott
  lilligant lilligant-hisui basculin basculegion basculegion-f krookodile scrafty zoroark
  zoroark-hisui cinccino gothitelle reuniclus swanna sawsbuck amoonguss alomomola galvantula
  eelektross chandelure haxorus beartic cryogonal mienshao golurk bisharp braviary
  braviary-hisui mandibuzz hydreigon volcarona cobalion terrakion virizion tornadus
  tornadus-therian thundurus thundurus-therian landorus landorus-therian keldeo-resolute
  meloetta chesnaught delphox greninja greninja-bond talonflame vivillon pyroar florges gogoat
  meowstic meowstic-f malamar dragalge clawitzer sylveon hawlucha dedenne carbink goodra
  goodra-hisui klefki trevenant avalugg-hisui noivern diancie hoopa volcanion decidueye
  decidueye-hisui incineroar primarina toucannon gumshoos vikavolt crabominable oricorio
  oricorio-pompom oricorio-pau oricorio-sensu ribombee lycanroc lycanroc-midnight lycanroc-dusk
  mudsdale araquanid lurantis salazzle tsareena comfey oranguru passimian palossand minior
  komala mimikyu bruxish kommoo necrozma magearna rillaboom cinderace inteleon greedent
  corviknight drednaw coalossal flapple appletun sandaconda cramorant barraskewda toxtricity
  polteageist hatterene grimmsnarl perrserker alcremie falinks pincurchin frosmoth stonjourner
  eiscue indeedee indeedee-f morpeko copperajah duraludon dragapult urshifu urshifu-rapidstrike
  zarude regieleki regidrago glastrier spectrier calyrex wyrdeer kleavor ursaluna
  ursaluna-bloodmoon enamorus enamorus-therian meowscarada skeledirge quaquaval oinkologne
  oinkologne-f spidops lokix pawmot maushold dachsbun arboliva squawkabilly squawkabilly-white
  squawkabilly-blue squawkabilly-yellow garganacl armarouge ceruledge bellibolt kilowattrel
  mabosstiff grafaiai brambleghast toedscruel klawf scovillain rabsca espathra tinkaton
  wugtrio bombirdier palafin revavroom cyclizar orthworm glimmora houndstone flamigo cetitan
  veluza dondozo tatsugiri farigiraf dudunsparce kingambit greattusk brutebonnet sandyshocks
  screamtail fluttermane slitherwing roaringmoon walkingwake irontreads ironmoth ironhands
  ironjugulis ironthorns ironbundle ironvaliant ironleaves baxcalibur gholdengo tinglu chienpao
  wochien chiyu dipplin sinistcha okidogi munkidori fezandipiti ogerpon ogerpon-wellspring
  ogerpon-hearthflame ogerpon-cornerstone archaludon hydrapple gougingfire ragingbolt
  ironboulder ironcrown terapagos pecharunt blissey chansey toxapex avalugg
)

# Species with female sprite variants (frontf flag in BattlePokemonSpritesBW, intersected with pool)
FEMALE_SPRITES=(
  venusaur pikachu raichu scyther gyarados meganium ledyba ledian xatu sudowoodo politoed
  aipom wooper quagsire murkrow unown wobbuffet girafarig gligar steelix scizor heracross
  sneasel ursaring piloswine octillery houndoom donphan blaziken beautifly dustox ludicolo
  nuzleaf shiftry meditite medicham roselia gulpin swalot numel camerupt cacturne milotic
  relicanth starly staravia staraptor bidoof bibarel kricketot kricketune shinx luxio luxray
  roserade combee pachirisu buizel floatzel ambipom gible gabite garchomp hippopotas hippowdon
  croagunk toxicroak finneon lumineon snover abomasnow weavile rhyperior tangrowth mamoswine
  unfezant frillish jellicent
)

fetch() {
  local dest="$1"
  local url="$2"
  if [ -f "$dest" ]; then
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  curl -fsSL --retry 3 -o "$dest" "$url" || echo "WARN: failed $url"
}

echo "==> Downloading data files..."
DATA_FILES=(
  pokedex.js moves.js items.js abilities.js search-index.js teambuilder-tables.js
  pokedex-mini.js pokedex-mini-bw.js typechart.js aliases.js commands.js text.js
)
for f in "${DATA_FILES[@]}"; do
  fetch "$CLIENT/data/$f" "$CDN/data/$f"
done

echo "==> Downloading gen5 front sprites (${#POOL_SPRITES[@]} Pokémon)..."
mkdir -p "$CLIENT/sprites/gen5"
for id in "${POOL_SPRITES[@]}"; do
  fetch "$CLIENT/sprites/gen5/${id}.png" "$CDN/sprites/gen5/${id}.png"
done

echo "==> Downloading gen5 back sprites..."
mkdir -p "$CLIENT/sprites/gen5-back"
for id in "${POOL_SPRITES[@]}"; do
  fetch "$CLIENT/sprites/gen5-back/${id}.png" "$CDN/sprites/gen5-back/${id}.png"
done

echo "==> Downloading female front sprites (${#FEMALE_SPRITES[@]} species)..."
for id in "${FEMALE_SPRITES[@]}"; do
  fetch "$CLIENT/sprites/gen5/${id}-f.png" "$CDN/sprites/gen5/${id}-f.png"
done

echo "==> Downloading gen6 battle backgrounds..."
mkdir -p "$CLIENT/sprites/gen6bgs"
for i in $(seq -w 01 19); do
  fetch "$CLIENT/sprites/gen6bgs/bg-${i}.jpg" "$CDN/sprites/gen6bgs/bg-${i}.jpg"
done

echo "==> Downloading icon sheets..."
for f in pokemonicons-sheet.png pokemonicons-pokeball-sheet.png itemicons-sheet.png; do
  fetch "$CLIENT/sprites/$f" "$CDN/sprites/$f"
done

echo "==> Downloading type icons..."
mkdir -p "$CLIENT/sprites/types"
TYPES=(Normal Fire Water Electric Grass Ice Fighting Poison Ground Flying Psychic Bug Rock Ghost Dragon Dark Steel Fairy)
for t in "${TYPES[@]}"; do
  fetch "$CLIENT/sprites/types/${t}.png" "$CDN/sprites/types/${t}.png"
done

echo "==> Downloading FX assets..."
mkdir -p "$CLIENT/fx"
FX_FILES=(
  bg-gen1.png bg-gen2.png weather-hail.png weather-sandstorm.png weather-sun.png
  weather-rain.png weather-snow.png item.png gender-f.png gender-m.png
)
for f in "${FX_FILES[@]}"; do
  fetch "$CLIENT/fx/$f" "$CDN/fx/$f"
done

echo "==> Done. All assets downloaded to $CLIENT."

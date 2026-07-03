import RandomTeams from '../gen9/teams';

const curatedSets: {[species: string]: any} = require('./sets.json');
const customSets: {[species: string]: any} = require('./custom-sets.json');

// Merge custom sets into the pool:
// - Pokémon already in the pool get their sets arrays extended.
// - New Pokémon (not in sets.json) are added to the pool with custom sets only.
const mergedSets: {[species: string]: any} = {...curatedSets};
for (const [species, data] of Object.entries(customSets) as [string, any][]) {
	if (species.startsWith('_comment')) continue;
	if (mergedSets[species]) {
		mergedSets[species] = {
			...mergedSets[species],
			sets: [...mergedSets[species].sets, ...data.sets],
		};
	} else {
		mergedSets[species] = data;
	}
}

export class RandomRandoMonTeams extends RandomTeams {
	// Pool = keys of this object. Real Pokémon use curated + custom sets;
	// new Pokémon (not in randbats) use custom sets only.
	override randomSets: {[species: string]: any} = mergedSets;
}

export default RandomRandoMonTeams;

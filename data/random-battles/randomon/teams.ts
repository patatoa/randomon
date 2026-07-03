import RandomTeams from '../gen9/teams';

export class RandomRandoMonTeams extends RandomTeams {
	// Pool = keys of this object; sets are loaded from the same file.
	override randomSets: {[species: string]: any} = require('./sets.json');
}

export default RandomRandoMonTeams;

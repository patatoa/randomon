export const Formats: import('../sim/dex-formats').FormatList = [
	{section: "Rando Mon"},
	{
		name: "[Gen 9] Rando Mon",
		desc: "Each player receives a randomly assigned team drawn from a 453-Pok&eacute;mon pool. No box legendaries, no pure stall. Sets and Tera types are hand-tuned per role.",
		mod: 'randomon',
		team: 'random',
		ruleset: ['Obtainable', 'Species Clause', 'HP Percentage Mod', 'Cancel Mod', 'Sleep Clause Mod'],
	},
];

const assert = require('assert').strict;
const fs = require('fs');
const path = require('path');
const {describe, it} = require('node:test');

const mainMenuSource = fs.readFileSync(
	path.resolve(__dirname, '../play.pokemonshowdown.com/src/panel-mainmenu.tsx'),
	'utf8'
);
const panelsSource = fs.readFileSync(
	path.resolve(__dirname, '../play.pokemonshowdown.com/src/panels.tsx'),
	'utf8'
);

describe('Randomon start screen', () => {
	it('uses the repository-defined Randomon format for matchmaking and ladder navigation', () => {
		assert.match(mainMenuSource, /const RANDOMON_FORMAT_ID = 'gen9randomon';/);
		assert.match(mainMenuSource, /this\.startSearch\(RANDOMON_FORMAT_ID/);
		assert.match(mainMenuSource, /href=\{`\/ladder-\$\{RANDOMON_FORMAT_ID\}`\}/);
	});

	it('uses existing Showdown identity and search APIs without a format selector', () => {
		const renderStart = mainMenuSource.slice(
			mainMenuSource.indexOf('renderRandomonStart()'),
			mainMenuSource.indexOf('override render()', mainMenuSource.indexOf('renderRandomonStart()'))
		);

		assert.match(mainMenuSource, /PS\.user\.changeName\(name\)/);
		assert.match(mainMenuSource, /continueRandomonBattleStart/);
		assert.match(mainMenuSource, /PS\.user\.named \? PS\.user\.name : ''/);
		assert.match(mainMenuSource, /\^guest\\d\+\$/);
		assert.doesNotMatch(renderStart, /TeamForm|FormatDropdown|formatselect/);
	});

	it('keeps retry, cancellation, and reconnect paths on the Randomon screen', () => {
		const renderStart = mainMenuSource.slice(
			mainMenuSource.indexOf('renderRandomonStart()'),
			mainMenuSource.indexOf('override render()', mainMenuSource.indexOf('renderRandomonStart()'))
		);

		assert.match(mainMenuSource, /this\.searchCountdown = null/);
		assert.match(mainMenuSource, /this\.search\.searching = this\.search\.searching\.filter/);
		assert.match(mainMenuSource, /cancelRandomonBattleStart/);
		assert.match(renderStart, /onClick=\{this\.cancelRandomonSearch\}/);
		assert.match(mainMenuSource, /data-cmd="\/reconnect"/);
	});

	it('does not render legacy lobby navigation in the Randomon start screen', () => {
		const renderStart = mainMenuSource.slice(
			mainMenuSource.indexOf('renderRandomonStart()'),
			mainMenuSource.indexOf('override render()', mainMenuSource.indexOf('renderRandomonStart()'))
		);

		for (const legacyLabel of [
			'Teambuilder', 'Tournaments', 'Watch a battle', 'Find a user', 'Friends', 'Info & Resources',
			'Chat rooms', 'Lobby chat',
		]) {
			assert.doesNotMatch(renderStart, new RegExp(legacyLabel));
		}
	});

	it('hides the standard Showdown header while the Randomon start screen is active', () => {
		assert.match(panelsSource, /const hideHeader = PS\.panel === PS\.mainmenu/);
		assert.match(panelsSource, /if \(hideHeader && room !== PS\.mainmenu\) continue/);
		assert.match(panelsSource, /\{!hideHeader && <PSHeader \/>\}/);
		assert.match(panelsSource, /randomon-home-room/);
	});
});

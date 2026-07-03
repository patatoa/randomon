/**
 * randomon-force.ts
 *
 * When Config.forcedformat is set:
 * - Overrides /challenge so all challenges use that format.
 * - Auto-accepts incoming challenges so the recipient doesn't need to click.
 */

export const Commands: Chat.ChatCommands = {
	challenge(target, room, user, connection) {
		const forcedFormat = (Config as any).forcedformat as string | null | undefined;
		if (forcedFormat) {
			const {targetUsername} = this.splitUser(target);
			target = `${targetUsername}, ${forcedFormat}`;
		}
		return (Chat.baseCommands!['challenge'] as Chat.ChatHandler).call(this, target, room, user, connection, 'challenge', '');
	},
};

export const Handlers: Chat.Handlers = {
	// Auto-accept the challenge on behalf of the target user.
	onChallenge(challenger, target, format) {
		if (!(Config as any).forcedformat) return;
		const connection = target.connections[0];
		if (!connection) return;
		// Give the challenge a tick to be fully registered before accepting.
		setImmediate(() => {
			const challs = Ladders.challenges.get(target.id);
			const chall = challs?.find(c => c.from === challenger.id);
			if (chall && 'ready' in chall && (chall as any).ready) {
				void Ladders.Ladder.acceptChallenge(connection, chall as any);
			}
		});
	},
};

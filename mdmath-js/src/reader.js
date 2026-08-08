import { exec } from 'node:child_process';
import { makeAsyncStream } from './async_stream.js';

// FIXME: This should not be a fatal error, instead send a response
// to the client with the error message.
function response_fail(message) {
    console.error(`Error: ${message}`);
    process.exit(1);
}

const reader = {}

reader.listen = function(callback) {
    const stream = makeAsyncStream(process.stdin, ':');

    async function loop() {
        while (await stream.waitReadable()) {
            const identifier = await stream.readString();
            const type = await stream.readString();
            if (type == 'request') {
                // TODO: Flags should be a enum
                const flags = await stream.readInt();

                const color = (await stream.readString()).toLowerCase();
                if (!color.match(/^#[0-9a-f]{6}$/))
                    throw new Error(`Invalid color format: ${color}`);

                const cellWidth = await stream.readInt();
                const width = await stream.readInt();

                const cellHeight = await stream.readInt();
                const height = await stream.readInt();

                const length = await stream.readInt();
                const data = await stream.readFixedString(length);

                const response = {
                    identifier,
                    type,
                    cellWidth,
                    cellHeight,
                    width,
                    height,
                    flags,
                    color,
                    data
                };
                callback(response);
            } else if(type == 'iscale' || type == 'dscale' || type == 'bfrac' || type == 'ilscale') {
                const scale = await stream.readFloat();

                const response = {
                    identifier,
                    type,
                    scale
                };
                callback(response);
            } else if (type == 'fontfamily') {
                const length = await stream.readInt();
                const data = await stream.readFixedString(length);

                const response = {
                    identifier,
                    type,
                    data
                };
                callback(response);
            } else {
                response_fail(`Identifier ${identifier}: Invalid request type: ${type}`);
            }
        }
    }

    loop();
}

export default reader;

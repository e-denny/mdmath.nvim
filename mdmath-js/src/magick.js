import { spawn, exec } from 'node:child_process';
import { stat } from 'node:fs';
// import { sendNotification, saveFile } from './debug.js';

function isValid(value) {
    return value !== undefined && value !== null;
}

/**
 * Checks if a file exists.
 *
 * @param {string} filename - The name of the file to check.
 * @returns {Promise<boolean>} A promise that resolves to true if the file exists, false otherwise.
 */
const fileExists = (filename) => new Promise((resolve, reject) => {
    stat(filename, (err, stats) => {
        if (err)
            return resolve(false);

        resolve(stats.isFile());
    });
});

const paths = process.env.PATH.split(':');
async function findBinary(name) {
    for (const path of paths) {
        if (await fileExists(`${path}/${name}`))
            return `${path}/${name}`;
    }
    return null;
}

const rsvgBinary = new Promise(async (resolve) => {
    const rsvg = await findBinary('rsvg-convert');
    if (rsvg === null) {
        console.error('Failed to find rsvg-convert! Make sure to have it properly installed.');
        process.exit(1);
    }
    return resolve(rsvg);
})

const magickBinary = new Promise(async (resolve) => {
    // ImageMagick v7
    const magick = await findBinary('magick');
    if (magick !== null) {
        return resolve({
            convert: magick,
            identify: magick,
            isV7: true
        });
    }

    // ImageMagick v6
    const convert = await findBinary('convert');
    if (convert === null) {
        console.error('Failed to find ImageMagick v6/v7 (found neither convert nor magick)');
        process.exit(1);
    }
    const identify = await findBinary('identify');
    if (identify === null) {
        console.error('Failed to find ImageMagick v6/v7 (found convert, but not identify)');
        process.exit(1);
    }

    return resolve({
        convert,
        identify,
        isV7: false
    });
});

/**
 * Gets the dimensions of a PNG buffer.
 *
 * @param {Buffer} png - The PNG buffer to measure.
 * @returns {Promise<{width: number, height: number}>} The dimensions of the PNG.
 */
export async function pngDimensions(png) {
    const magick = await magickBinary;

    const args = [];
    if (magick.isV7)
        args.push('identify')
    args.push('-ping');
    args.push('-format', '%w %h');
    args.push('png:-');

    return new Promise((resolve, reject) => {
        const p = spawn(magick.identify, args);
        let data = '';
        p.stdout.on('data', (chunk) => data += chunk);
        p.on('close', (code) => {
            // TODO: improve error handling
            if (code !== 0)
                return reject(new Error(`pngDimensions: identify exited with code ${code}`));

            const [width, height] = data.trim().split(' ').map(Number);
            resolve({width, height});
        });
        p.stdin.write(png);
        p.stdin.end();
    });
}

/**
 * Fits a PNG image to specified dimensions.
 *
 * @param {Buffer} input - The input PNG buffer.
 * @param {string} output - The output filename.
 * @param {number} width - The target width.
 * @param {number} height - The target height.
 * @param {Object} options - Options for fitting the image.
 * @param {boolean} options.center - Whether to center the image in the output dimensions.
 * @param {number} [options.yOffset] - Top padding in pixels (overrides center; places image at this y offset).
 * @returns {Promise<{width: number, height: number}>} The dimensions of the output image.
 */
export async function pngFitTo(input, output, width, height, {center, yOffset}) {
    const size = `${width}x${height}`;

    let args;
    if (yOffset !== undefined && yOffset !== null) {
        const offset = Math.round(yOffset);
        if (offset >= 0) {
            // Add transparent rows at top, then crop canvas to target size
            args = ['png:-', '-background', 'none', '-splice', `0x${offset}`, '-extent', size];
        } else {
            // Remove rows from top (image overflows above cell), then pad bottom to target size
            args = ['png:-', '-background', 'none', '-chop', `0x${-offset}`,
                    '-gravity', 'North', '-extent', size];
        }
    } else {
        args = ['png:-', '-background', 'none', '-gravity', center ? 'Center' : 'West', '-extent', size];
    }
    args.push(`png:${output}`);

    const magick = await magickBinary;

    return new Promise((resolve, reject) => {
        const p = spawn(magick.convert, args);
        let stderr = '';
        p.stderr.on('data', (chunk) => stderr += chunk);
        p.on('close', (code) => {
            if (code !== 0)
                return reject(new Error(`pngFitTo: ${stderr}`));

            resolve({width, height});
        });
        p.stdin.write(input);
        p.stdin.end();
    });
}

/**
 * Converts an SVG string to a PNG using rsvg-convert.
 *
 * @param {string} svg - The SVG string to convert.
 * @param {Object} opts - Conversion options.
 * @param {number} [opts.width] - The target width.
 * @param {number} [opts.height] - The target height.
 * @param {number} [opts.zoom] - The zoom factor to apply.
 * @returns {Promise<Buffer>} The resulting PNG as a buffer.
 */
export async function rsvgConvert(svg, opts) {
    const rsvg = await rsvgBinary;

    const args = [];
    args.push('--keep-aspect-ratio');
    args.push('--format', 'png');
    if (isValid(opts.width))
        args.push('--width', opts.width);
    if (isValid(opts.height))
        args.push('--height', opts.height);
    if (isValid(opts.zoom))
        args.push('--zoom', opts.zoom);

    return new Promise((resolve, reject) => {
        const p = spawn(rsvg, args);
        let chunks = [];
        p.stdout.on('data', (chunk) => chunks.push(chunk));
        p.on('close', (code) => {
            if (code !== 0)
                return reject(new Error(`rsvg-convert: exited with code ${code}`));

            const data = Buffer.concat(chunks);
            resolve(data);
        });
        p.stdin.write(svg);
        p.stdin.end();
    });
}

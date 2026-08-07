import fs from 'fs';
import mathjax from 'mathjax';
import reader from './reader.js';
import { pngDimensions, pngFitTo, rsvgConvert } from './magick.js';
import { sendNotification, saveFile } from './debug.js';
import { sha256Hash } from './util.js';
import { randomBytes } from 'node:crypto';
import { onExit } from './onexit.js';

// To prevent conflicts with other instances
const DIRECTORY_SUFFIX = randomBytes(3).toString('hex');

// TODO: Portable directory instead of Unix-specific
const IMG_DIR = `/tmp/nvim-mdmath-${DIRECTORY_SUFFIX}`;

/** @typedef {{equation: string, filename: string}} Equation */

/** @type {Equation[]} */
const equations = [];

/** @type {Object.<string, Equation>} */
const equationMap = {};

const svgCache = {};

let internalScale = 1;
let dynamicScale = 1;
let inlineScale = 1;
// Fraction of cell height from top to the terminal font's baseline (win ascent / (win ascent + win descent)).
// Typical value for monospace fonts: 0.78-0.80.
let baselineFrac = 0.78;

let MathJax = undefined;

class MathError extends Error {
    constructor(message) {
        super(message);
        this.name = 'MathError';
    }
}

function mkdirSync(path) {
    try {
        fs.mkdirSync(path, { recursive: true });
    } catch (err) {
        if (err.code !== 'EEXIST')
            throw err;
    }
}

/**
 * @param {string} equation
 * @returns {Promise<{svg: string} | {error: string}>}
 */
async function equationToSVG(equation) {
    if (equation in svgCache)
        return svgCache[equation];

    try {
        const svg = await MathJax.tex2svgPromise(equation);
        return svgCache[equation] = {
            svg: MathJax.startup.adaptor.innerHTML(svg)
        }
    } catch (err) {
        if (err instanceof MathError) {
            return svgCache[equation] = {
                error: err.message
            }
        } else {

        }

        throw err;
    }
}

function write(identifier, width, height, data) {
    process.stdout.write(`${identifier}:image:${width}:${height}:${data.length}:${data}`);
}

function writeError(identifier, error) {
    process.stdout.write(`${identifier}:error:0:0:${error.length}:${error}`);
}

function parseViewbox(svgString) {
    const viewboxMatch = svgString.match(/viewBox="([^"]+)"/);
    if (!viewboxMatch) return null;

    const [minX, minY, width, height] = viewboxMatch[1].split(' ').map(parseFloat);
    return { minX, minY, width, height };
}

// Returns {descentEx, totalEx} parsed from MathJax SVG style/height attributes.
// descentEx is the depth below the baseline; totalEx is the full height, both in ex units.
function parseBaselineMetrics(svgString) {
    const styleMatch = svgString.match(/style="[^"]*vertical-align:\s*(-?[\d.]+)ex/);
    const heightMatch = svgString.match(/\sheight="([\d.]+)ex"/);
    if (!styleMatch || !heightMatch) return null;

    const descentEx = -parseFloat(styleMatch[1]); // vertical-align is negative for descent
    const totalEx = parseFloat(heightMatch[1]);
    return { descentEx, totalEx };
}

/**
  * @param {string} identifier
  * @param {string} equation
*/
async function processEquation(identifier, equation, cWidth, cHeight, width, height, flags, color) {
    if (!equation || equation.trim().length === 0)
        return writeError(identifier, 'Empty equation')

    const equation_key = `${equation}_${cWidth}*${width}x${cHeight}*${height}_${flags}_${color}`;
    if (equation_key in equationMap) {
        const equationObj = equationMap[equation_key];
        return write(identifier, equationObj.width, equationObj.height, equationObj.filename);
    }

    let {svg, error} = await equationToSVG(equation);
    if (!svg)
        return writeError(identifier, error)

    const baselineMetrics = parseBaselineMetrics(svg);

    svg = svg
        .replace(/currentColor/g, color)
        .replace(/style="[^"]+"/, '')

    const isDynamic = !!(flags & 1);
    const isCenter = !!(flags & 2);

    const zoom = 10 * dynamicScale * cHeight * internalScale / 96;
    const inlineZoom = 10 * dynamicScale * inlineScale * cHeight * internalScale / 96;

    let basePNG;
    let iWidth, iHeight;
    let renderedHeightPx = null;
    if (isDynamic) {
        basePNG = await rsvgConvert(svg, {zoom});

        const {width: pngWidth, height: pngHeight} = await pngDimensions(basePNG);

        const newWidth = (pngWidth / internalScale) / cWidth;
        const newHeight = (pngHeight / internalScale) / cHeight;

        // If the image is smaller than the cell, it's better to keep the original size, so
        width = Math.max(width, Math.ceil(newWidth));
        height = Math.max(height, Math.ceil(newHeight));

        iWidth = width * cWidth * internalScale;
        iHeight = height * cHeight * internalScale;
    } else if (isCenter && baselineMetrics) {
        // Render at the inline zoom to get accurate physical dimensions, then
        // pad to a cell-aligned canvas via pngFitTo.
        basePNG = await rsvgConvert(svg, {zoom: inlineZoom});

        const {height: pngHeight} = await pngDimensions(basePNG);
        renderedHeightPx = pngHeight;

        // Keep inline equations at exactly 1 cell row. Kitty renders the full
        // image regardless, so tall equations (superscripts, etc.) overflow into
        // surrounding cell space without displacing text below.
        height = 1;
        iWidth = width * cWidth * internalScale;
        iHeight = Math.max(pngHeight, cHeight * internalScale);
    } else {
        iWidth = width * cWidth * internalScale;
        iHeight = height * cHeight * internalScale;

        basePNG = await rsvgConvert(svg, {width: iWidth, height: iHeight});
    }

    const hash = sha256Hash(equation).slice(0, 7);
    const filename = `${IMG_DIR}/${hash}_${iWidth}x${iHeight}.png`;

    // For inline equations, align the image to the text baseline using MathJax's
    // vertical-align metric. Place the PNG so the equation's visual baseline
    // lands at the terminal cell baseline.
    //
    // The terminal baseline sits at a fixed fraction of the cell height determined
    // by the font's win ascent/descent metrics. For most monospace fonts in Kitty
    // this is ~0.78-0.80. The equation's ascent above its own baseline is
    // (1 - descentFrac) * renderedHeightPx.
    let fitOpts;
    if (isCenter && baselineMetrics && renderedHeightPx !== null) {
        const { descentEx, totalEx } = baselineMetrics;
        const descentFrac = descentEx / totalEx;
        const cellPx = cHeight * internalScale;
        // Terminal baseline position from top of cell (font win ascent fraction)
        const terminalBaselinePx = baselineFrac * cellPx;
        // Equation's ascent in px (height above its own baseline)
        const equationAscent = (1 - descentFrac) * renderedHeightPx;
        // No clamp: negative yOffset means the equation overflows above the cell top,
        // which ImageMagick's -extent will clip. This ensures all equations share the
        // same baseline regardless of height.
        const yOffset = terminalBaselinePx - equationAscent;
        fitOpts = {yOffset};
    } else {
        fitOpts = {center: isCenter};
    }

    await pngFitTo(basePNG, filename, iWidth, iHeight, fitOpts);

    const equationObj = {equation, filename, width, height};
    equations.push(equationObj);
    equationMap[equation_key] = equationObj;

    write(identifier, width, height, filename);
}

function processAll(request) {
    if (request.type === 'request') {
        return processEquation(
            request.identifier,
            request.data,
            request.cellWidth,
            request.cellHeight,
            request.width,
            request.height,
            request.flags,
            request.color
        ).catch((err) => {
            writeError(request.identifier, err.message);
        });
    } else if (request.type === 'dscale') {
        // FIXME: Invalidate cache when scale changes
        dynamicScale = request.scale;
    } else if (request.type === 'iscale') {
        // FIXME: Invalidate cache when scale changes
        internalScale = request.scale;
    } else if (request.type === 'bfrac') {
        baselineFrac = request.scale;
    } else if (request.type === 'ilscale') {
        inlineScale = request.scale;
    }
}

function main() {
    mkdirSync(IMG_DIR);

    onExit(() => {
        equations.forEach(({filename}) => {
            try {
                fs.unlinkSync(filename);
            } catch (err) {}
        });

        try {
            fs.rmdirSync(IMG_DIR);
        } catch (err) {}
    });

    mathjax.init({
        loader: { load: ['input/tex', 'output/svg'] },
        tex: {
            formatError: (_, err) => {
                throw new MathError(err.message);
            }
        }
    }).then((MathJax_) => {
        MathJax = MathJax_;
        reader.listen(processAll);
    }).catch((err) => {
        console.error(err);
        process.exit(1);
    });
}

main();

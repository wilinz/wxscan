// The scanner, off the main thread.
//
// Both WebAssembly modules live in here: the scanner itself, and the TensorFlow
// Lite runtime it asks for forward passes. Frames arrive as transferred buffers
// and results leave as JSON, which is the one shape that survives postMessage —
// the C ABI returns pointers into this worker's memory, which do not.
//
// Messages in:  {id, cmd: 'init', wxscan, tflite, detect, sr}
//               {id, cmd: 'scanGray',   pixels, width, height}
//               {id, cmd: 'scanPixels', pixels, width, height, format}
//               {id, cmd: 'scanFrame',  pixels, width, height, rowStride, rotation, mirror}
//               {id, cmd: 'dispose'}
// Messages out: {id, ok: true, ...} | {id, ok: false, error}

let tf = null;        // the TFLite module, or null when decoding without models
let wx = null;        // the scanner module's exports
let scanner = 0;
let pending = null;   // the descriptor prepared by the last forward pass

const memory = () => wx.memory.buffer;

function hostForward(net, inputPtr, len, shapePtr, rank) {
  if (!tf) return 0;
  const shape = new Uint32Array(memory(), shapePtr, rank);
  // The module speaks NCHW; the models are NHWC with one channel, so only the
  // dimensions are reordered, never the data.
  const height = rank === 4 ? shape[2] : 1;
  const width = rank === 4 ? shape[3] : len;

  const inputAddress = tf._tf_prepare(net, height, width);
  if (!inputAddress) return 0;
  new Float32Array(tf.HEAPF32.buffer, inputAddress, len)
    .set(new Float32Array(memory(), inputPtr, len));

  const count = tf._tf_invoke(net);
  if (count < 0) return 0;

  const header = [count];
  const parts = [];
  for (let i = 0; i < count; i++) {
    const rank = tf._tf_out_rank(net, i);
    const dims = [];
    for (let d = 0; d < rank; d++) dims.push(tf._tf_out_dim(net, i, d));
    const nchw = (rank === 4 && dims[3] === 1)
      ? [dims[0], 1, dims[1], dims[2]]
      : dims;
    header.push(nchw.length, ...nchw);
    const floats = tf._tf_out_floats(net, i);
    parts.push(new Float32Array(tf.HEAPF32.buffer, tf._tf_out_ptr(net, i), floats).slice());
  }

  const words = new Uint32Array(header.length + parts.reduce((a, p) => a + p.length, 0));
  words.set(header, 0);
  let offset = header.length;
  for (const part of parts) {
    new Float32Array(words.buffer, offset * 4, part.length).set(part);
    offset += part.length;
  }
  pending = new Uint8Array(words.buffer);
  return pending.byteLength;
}

function hostFetch(destination, length) {
  if (!pending || pending.byteLength !== length) return 0;
  new Uint8Array(memory(), destination, length).set(pending);
  pending = null;
  return 1;
}

async function init({ wxscan, tflite, detect, sr }) {
  if (tflite) {
    const factory = (await import(tflite)).default;
    tf = await factory();
    const put = (bytes) => {
      const p = tf._malloc(bytes.length);
      tf.HEAPU8.set(bytes, p);
      return p;
    };
    const d = new Uint8Array(detect), s = new Uint8Array(sr);
    if (!tf._tf_load(put(d), d.length, put(s), s.length)) {
      throw new Error('the weights would not load');
    }
  }

  const { instance } = await WebAssembly.instantiate(new Uint8Array(wxscan), {
    wxscan: { wxscan_host_forward: hostForward, wxscan_host_fetch: hostFetch },
  });
  wx = instance.exports;

  scanner = tf
    ? wx.wxscan_scanner_new_host(1, 1)
    : wx.wxscan_scanner_new_host(0, 0);
  if (!scanner) throw new Error('the scanner would not start');

  return {
    hasDetector: wx.wxscan_scanner_has_detector(scanner) !== 0,
    hasSuperResolution: wx.wxscan_scanner_has_super_resolution(scanner) !== 0,
  };
}

function scan(cmd, m) {
  const bytes = new Uint8Array(m.pixels);
  const address = wx.malloc(bytes.length);
  try {
    new Uint8Array(memory(), address, bytes.length).set(bytes);
    const packed =
      cmd === 'scanPixels'
        ? wx.wxscan_wasm_scan_pixels_json(scanner, address, m.width, m.height, m.format)
        : cmd === 'scanFrame'
          ? wx.wxscan_wasm_scan_frame_json(scanner, address, m.width, m.height,
              m.rowStride, m.rotation, m.mirror ? 1 : 0)
          : wx.wxscan_wasm_scan_gray_json(scanner, address, m.width, m.height);
    // The module answers with (address << 32) | length in one i64.
    const stringAddress = Number(packed >> 32n);
    const length = Number(packed & 0xffffffffn);
    if (!stringAddress) return { json: null };
    try {
      const json = new TextDecoder().decode(
        new Uint8Array(memory(), stringAddress, length));
      return { json };
    } finally {
      wx.wxscan_wasm_string_free(stringAddress, length);
    }
  } finally {
    wx.free(address);
  }
}

self.onmessage = async (event) => {
  const { id, cmd } = event.data;
  try {
    let result;
    if (cmd === 'init') result = await init(event.data);
    else if (cmd === 'scanGray' || cmd === 'scanPixels' || cmd === 'scanFrame')
      result = scan(cmd, event.data);
    else if (cmd === 'dispose') {
      if (scanner) wx.wxscan_scanner_free(scanner);
      scanner = 0;
      result = {};
    } else throw new Error(`unknown command ${cmd}`);
    self.postMessage({ id, ok: true, ...result });
  } catch (e) {
    self.postMessage({ id, ok: false, error: String((e && e.stack) || e) });
  }
};

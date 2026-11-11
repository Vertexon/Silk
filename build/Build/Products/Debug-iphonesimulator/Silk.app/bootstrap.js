/*
 * Silk — Pyodide bridge (runs in a headless WKWebView).
 *
 * Swift -> JS
 *   SpyderBridge.boot({ indexURLs, packages, dpi })
 *   SpyderBridge.execute({ id, code })
 *   SpyderBridge.refresh({ id })
 *   SpyderBridge.preview({ id, name })
 *   SpyderBridge.help({ id, symbol })
 *   SpyderBridge.deleteVariable({ id, name })
 *   SpyderBridge.clearVariables({ id })
 *   SpyderBridge.listFiles({ id })
 *   SpyderBridge.writeFile({ id, name, base64 })
 *   SpyderBridge.readFile({ id, name })
 *   SpyderBridge.deleteFile({ id, name })
 *
 * JS -> Swift (window.webkit.messageHandlers.spyder)
 *   { type: "status",  detail }
 *   { type: "stdout",  stream: "stdout" | "stderr", text }
 *   { type: "ready",   version, packages }
 *   { type: "result",  id, ok, error?, durationMs, variables, plots }
 *   { type: "workspace", id, variables }
 *   { type: "preview", id, preview }
 *   { type: "help",    id, help }
 *   { type: "variableDeleted", id, name, removed }
 *   { type: "variablesCleared", id, count }
 *   { type: "files", id, files, error? }
 *   { type: "fileData", id, name, base64, size, error? }
 *   { type: "fileOperation", id, name, ok, size?, error? }
 *   { type: "failure", message }
 *   { type: "log",     message }
 */
(function () {
  "use strict";

  if (window.SpyderBridge) { return; }

  const bridge = {};
  window.SpyderBridge = bridge;

  const state = {
    pyodide: null,
    booting: false,
    booted: false,
    running: false,
    scriptURL: null,
    packages: [],
    dpi: 120,
  };

  // MARK: Swift transport

  function post(payload) {
    try {
      window.webkit.messageHandlers.spyder.postMessage(payload);
    } catch (error) {
      console.error("[spyder] message handler unavailable", error);
    }
  }

  function status(detail) {
    post({ type: "status", phase: "boot", detail: String(detail || "") });
  }

  function describeError(error) {
    if (!error) { return "Unknown error."; }
    if (typeof error === "string") { return error; }
    if (error.message) { return String(error.message); }
    return String(error);
  }

  // MARK: Streaming stdout / stderr

  function makeWriter(stream) {
    const decoder = new TextDecoder("utf-8");
    let pending = "";

    function flushPending() {
      if (!pending) { return; }
      post({ type: "stdout", stream: stream, text: pending });
      pending = "";
    }

    return {
      isatty: false,
      write(buffer) {
        pending += decoder.decode(buffer, { stream: true });
        if (pending.length >= 4096 || pending.indexOf("\n") !== -1) {
          flushPending();
        }
        // Emscripten expects the number of bytes consumed.
        return buffer.length;
      },
      flush() {
        const tail = decoder.decode();
        if (tail) { pending += tail; }
        flushPending();
      },
    };
  }

  let stdoutWriter = null;
  let stderrWriter = null;

  function flushOutputStreams() {
    if (stdoutWriter) { stdoutWriter.flush(); }
    if (stderrWriter) { stderrWriter.flush(); }
  }

  // MARK: Interactive input

  // Bridges Python's stdin to a native text prompt. window.prompt blocks the
  // page's JavaScript until WKWebView's UI delegate answers, which is what lets
  // Pyodide's synchronous input() receive a real line instead of EOF.
  function nativeInput(promptText) {
    flushOutputStreams();

    let response = null;
    try {
      response = window.prompt(String(promptText || ""), "");
    } catch (error) {
      console.error("[spyder] native prompt failed", error);
      return null;
    }

    if (response === null || response === undefined) {
      return null;
    }

    const value = String(response);
    // Echo the entered line so the console reads like a terminal transcript.
    post({ type: "stdout", stream: "stdout", text: value + "\n" });
    return value;
  }

  // MARK: Python instrumentation

  const PYTHON_INIT = String.raw`
import base64
import builtins
import inspect
import io
import sys
import types

_SPYDER_DPI = __SPYDER_DPI__
_SPYDER_MAX_PLOTS = 10
_SPYDER_PLOTS = []


def _spyder_input(prompt=""):
    """Replacement for builtins.input() that asks the host app for a line.
    Cancelling the native panel raises EOFError, exactly like Ctrl-D."""
    if prompt:
        sys.stdout.write(str(prompt))
        sys.stdout.flush()
    try:
        value = _spyder_native_input(str(prompt))
    except Exception as error:
        raise EOFError("input() is unavailable: " + str(error))
    if value is None:
        raise EOFError("EOF when reading a line")
    return str(value)


_SPYDER_ORIGINAL_INPUT = builtins.input
builtins.input = _spyder_input


def _spyder_png_size(payload):
    if len(payload) < 24 or payload[:8] != b"\x89PNG\r\n\x1a\n":
        return (0, 0)
    return (int.from_bytes(payload[16:20], "big"), int.from_bytes(payload[20:24], "big"))


def _spyder_push(item):
    if len(_SPYDER_PLOTS) < _SPYDER_MAX_PLOTS:
        _SPYDER_PLOTS.append(item)


def _spyder_capture(fig):
    buffer = io.BytesIO()
    fig.savefig(
        buffer,
        format="png",
        dpi=_SPYDER_DPI,
        bbox_inches="tight",
        pad_inches=0.08,
        facecolor=fig.get_facecolor(),
    )
    raw = buffer.getvalue()
    buffer.close()
    width, height = _spyder_png_size(raw)
    return {
        "png": base64.b64encode(raw).decode("ascii"),
        "width": width,
        "height": height,
        "figure": int(getattr(fig, "number", 0) or 0),
    }


def _spyder_show(*args, **kwargs):
    """Replacement for plt.show(): rasterize every open figure instead of
    asking a GUI backend to display it."""
    import matplotlib.pyplot as plt

    for number in list(plt.get_fignums()):
        try:
            _spyder_push(_spyder_capture(plt.figure(number)))
        except Exception:
            pass
    plt.close("all")


def _spyder_take_plots():
    """Captures figures the user never called show() on, then drains the queue."""
    import matplotlib.pyplot as plt

    for number in list(plt.get_fignums()):
        try:
            _spyder_push(_spyder_capture(plt.figure(number)))
        except Exception:
            pass
    plt.close("all")
    items = list(_SPYDER_PLOTS)
    _SPYDER_PLOTS.clear()
    return items


def _spyder_kind(value):
    import numpy as np

    module = type(value).__module__
    name = type(value).__name__
    if isinstance(value, np.ndarray):
        return "array"
    if module.startswith("pandas"):
        if name == "DataFrame":
            return "dataframe"
        if name == "Series":
            return "series"
    if isinstance(value, (list, tuple, set, frozenset, range)):
        return "list"
    if isinstance(value, dict):
        return "dictionary"
    if isinstance(value, str):
        return "string"
    if isinstance(value, (bool, np.bool_)):
        return "boolean"
    if isinstance(value, (int, float, complex, np.number)):
        return "number"
    if callable(value):
        return "function"
    return "object"


def _spyder_shape(value):
    shape = getattr(value, "shape", None)
    if shape is not None:
        try:
            dimensions = [int(item) for item in shape]
        except Exception:
            dimensions = []
        if dimensions:
            return "x".join(str(item) for item in dimensions)
        return "scalar"
    if isinstance(value, (list, tuple, set, frozenset, dict, str, bytes, bytearray)):
        return "len " + str(len(value))
    return "-"


def _spyder_summary(value):
    if callable(value):
        name = getattr(value, "__name__", None)
        if name:
            return "def " + str(name) + "()"
    try:
        text = repr(value)
    except Exception as error:
        return "<unreadable: " + type(error).__name__ + ">"
    text = " ".join(text.split())
    if len(text) > 170:
        text = text[:169] + "..."
    return text


def _spyder_type_name(value):
    cls = type(value)
    if cls.__module__ in ("builtins", "__main__"):
        return cls.__name__
    return cls.__module__ + "." + cls.__name__


def _spyder_cell(value):
    try:
        # NumPy 2 reprs scalars as np.int64(1); Spyder shows the bare value.
        if type(value).__module__.split(".")[0] == "numpy" and hasattr(value, "item"):
            value = value.item()
        text = repr(value)
    except Exception as error:
        return "<" + type(error).__name__ + ">"
    text = " ".join(text.split())
    if len(text) > 60:
        text = text[:59] + "..."
    return text


def _spyder_inspect(name):
    namespace = globals()
    if name not in namespace:
        return {
            "name": name,
            "kind": "object",
            "columns": [],
            "rows": [],
            "totalRows": 0,
            "totalColumns": 0,
            "note": "",
            "repr": "",
            "error": "Variable '" + name + "' is no longer defined.",
        }

    value = namespace[name]
    kind = _spyder_kind(value)
    rendered = _spyder_summary(value)
    max_rows = 100
    max_columns = 10
    columns = []
    rows = []
    note = ""
    total_rows = 1
    total_columns = 1

    try:
        if kind == "array":
            dtype = "dtype " + str(value.dtype)
            if value.ndim == 0:
                columns = ["Name", "Value"]
                rows = [[name, _spyder_cell(value)]]
                note = dtype
            elif value.ndim == 1:
                total_rows = int(value.shape[0])
                columns = ["Index", "Value"]
                for index in range(min(total_rows, max_rows)):
                    rows.append([str(index), _spyder_cell(value[index])])
                note = dtype
            else:
                matrix = value.reshape(-1, value.shape[-1]) if value.ndim > 2 else value
                total_rows = int(matrix.shape[0])
                total_columns = int(matrix.shape[1])
                shown = min(total_columns, max_columns)
                columns = ["Index"] + [str(index) for index in range(shown)]
                for row_index in range(min(total_rows, max_rows)):
                    row = [str(row_index)]
                    for column_index in range(shown):
                        row.append(_spyder_cell(matrix[row_index, column_index]))
                    rows.append(row)
                note = dtype
                if value.ndim > 2:
                    note += " · N-D array flattened to 2-D"
                if total_columns > shown:
                    note += " · " + str(shown) + " of " + str(total_columns) + " columns"

        elif kind == "dataframe":
            total_rows = int(len(value))
            total_columns = int(len(value.columns))
            shown = min(total_columns, max_columns)
            columns = ["Index"] + [str(column) for column in list(value.columns)[:shown]]
            for row_index in range(min(total_rows, max_rows)):
                row = [str(value.index[row_index])]
                for column_index in range(shown):
                    row.append(_spyder_cell(value.iloc[row_index, column_index]))
                rows.append(row)
            note = "dtypes: " + ", ".join(str(item) for item in list(value.dtypes)[:shown])
            if total_columns > shown:
                note += " · " + str(shown) + " of " + str(total_columns) + " columns"

        elif kind == "series":
            total_rows = int(len(value))
            columns = ["Index", "Value"]
            for row_index in range(min(total_rows, max_rows)):
                rows.append([str(value.index[row_index]), _spyder_cell(value.iloc[row_index])])
            note = "dtype " + str(value.dtype)

        elif kind == "dictionary":
            items = list(value.items())
            total_rows = len(items)
            total_columns = 2
            columns = ["Key", "Value"]
            for key, item in items[:max_rows]:
                rows.append([_spyder_cell(key), _spyder_cell(item)])
            note = "dict · " + str(len(items)) + " entries"

        elif kind == "list":
            items = list(value)
            total_rows = len(items)
            columns = ["Index", "Value"]
            for index, item in enumerate(items[:max_rows]):
                rows.append([str(index), _spyder_cell(item)])
            note = type(value).__name__ + " · " + str(len(items)) + " items"

        elif kind == "string":
            lines = value.splitlines() or [""]
            total_rows = len(lines)
            columns = ["Line", "Text"]
            for index, line in enumerate(lines[:max_rows]):
                rows.append([str(index + 1), line[:200]])
            note = "str · " + str(len(value)) + " characters"

        else:
            columns = ["Name", "Value"]
            rows = [[name, rendered]]
            note = _spyder_type_name(value)
    except Exception as error:
        return {
            "name": name,
            "kind": kind,
            "columns": [],
            "rows": [],
            "totalRows": 0,
            "totalColumns": 0,
            "note": "",
            "repr": rendered,
            "error": type(error).__name__ + ": " + str(error),
        }

    if total_rows > max_rows:
        note += " · showing " + str(max_rows) + " of " + str(total_rows) + " rows"

    return {
        "name": name,
        "kind": kind,
        "columns": columns,
        "rows": rows,
        "totalRows": total_rows,
        "totalColumns": total_columns,
        "note": note,
        "repr": rendered,
        "error": "",
    }


def _spyder_import_namespace(source_text):
    """Builds a namespace from the file's import statements so Docs can resolve
    aliases like np before the cell has been run."""
    import ast

    if not source_text:
        return {}
    try:
        tree = ast.parse(source_text)
    except Exception:
        return {}

    staging = {}
    for node in tree.body:
        if not isinstance(node, (ast.Import, ast.ImportFrom)):
            continue
        try:
            module = ast.Module(body=[node], type_ignores=[])
            exec(compile(module, "<spyder-docs>", "exec"), staging)
        except Exception:
            continue
    return staging


def _spyder_help(name, source_text=""):
    namespace = globals()
    try:
        target = eval(name, namespace)
    except Exception:
        target = None

    if target is None:
        imported = _spyder_import_namespace(source_text)
        if imported:
            try:
                target = eval(name, imported)
            except Exception:
                target = imported.get(name)

    if target is _spyder_input:
        target = _SPYDER_ORIGINAL_INPUT

    builtins_module = __import__("builtins")
    if target is None and hasattr(builtins_module, name):
        target = getattr(builtins_module, name)

    if target is None:
        return {
            "symbol": name,
            "title": name,
            "signature": name,
            "module": "",
            "doc": "",
            "error": "No object named '" + name + "' is defined in the session or the file's imports.",
        }

    module = getattr(target, "__module__", "") or ""
    if not module:
        module = type(target).__module__

    try:
        signature = name + str(inspect.signature(target))
    except Exception:
        signature = name

    doc = ""
    try:
        doc = inspect.getdoc(target) or ""
    except Exception:
        doc = ""
    if not doc:
        doc = getattr(target, "__doc__", "") or ""
    doc = doc.strip()
    if len(doc) > 4000:
        doc = doc[:3999] + "…"

    title = getattr(target, "__name__", None) or type(target).__name__
    return {
        "symbol": name,
        "title": str(title),
        "signature": signature,
        "module": str(module),
        "doc": doc,
        "error": "",
    }


def _spyder_delete(name):
    namespace = globals()
    if name in namespace:
        del namespace[name]
        return True
    return False


def _spyder_list_files():
    import os

    root = os.getcwd()
    files = []
    try:
        names = sorted(os.listdir(root))
    except Exception:
        names = []
    for name in names:
        if name.startswith("."):
            continue
        path = os.path.join(root, name)
        if not os.path.isfile(path):
            continue
        try:
            size = os.path.getsize(path)
        except Exception:
            size = 0
        files.append({"name": name, "size": int(size)})
    return {"directory": root, "files": files}


def _spyder_clear_workspace():
    protected = {"base64", "builtins", "inspect", "io", "sys", "types", "matplotlib"}
    removed = 0
    for name in list(globals().keys()):
        if name.startswith("_") or "spyder" in name or name in protected:
            continue
        globals().pop(name, None)
        removed += 1
    return removed


def _spyder_workspace():
    variables = []
    for name, value in list(globals().items()):
        if name.startswith("_") or "spyder" in name:
            continue
        if isinstance(value, types.ModuleType):
            continue
        try:
            variables.append({
                "name": name,
                "type": _spyder_type_name(value),
                "shape": _spyder_shape(value),
                "summary": _spyder_summary(value),
                "kind": _spyder_kind(value),
            })
        except Exception:
            continue
        if len(variables) >= 300:
            break
    variables.sort(key=lambda item: item["name"].lower())
    return {"variables": variables, "count": len(variables)}


# Matplotlib must render off-screen: the webagg backend wants a DOM canvas per
# figure, while AGG writes straight into a BytesIO buffer we can base64.
import matplotlib

matplotlib.use("AGG", force=True)
import matplotlib.pyplot as _spyder_plt

_spyder_plt.show = _spyder_show
del _spyder_plt

import numpy as _spyder_numpy
del _spyder_numpy
`;

  function pythonInitSource(dpi) {
    return PYTHON_INIT.replace("__SPYDER_DPI__", String(dpi));
  }

  // MARK: Boot

  function loadRuntimeScript(indexURL) {
    return new Promise(function (resolve, reject) {
      if (state.scriptURL === indexURL && typeof window.loadPyodide === "function") {
        resolve();
        return;
      }
      const script = document.createElement("script");
      script.src = indexURL + "pyodide.js";
      script.async = true;
      script.onload = function () {
        state.scriptURL = indexURL;
        resolve();
      };
      script.onerror = function () {
        reject(new Error("Unable to load " + script.src));
      };
      document.head.appendChild(script);
    });
  }

  async function boot(configuration) {
    if (state.booted) {
      post({ type: "ready", version: state.pyodide.version, packages: state.packages });
      return;
    }
    if (state.booting) { return; }

    state.booting = true;
    state.dpi = Number(configuration && configuration.dpi) || 120;

    const indexURLs = Array.isArray(configuration && configuration.indexURLs)
      ? configuration.indexURLs
      : [];
    const packages = Array.isArray(configuration && configuration.packages)
      ? configuration.packages
      : ["numpy", "matplotlib", "scipy", "pandas", "sympy"];

    let lastError = null;

    for (let index = 0; index < indexURLs.length; index += 1) {
      const indexURL = indexURLs[index];
      try {
        status(index === 0 ? "Starting the Python runtime..." : "Retrying with the web runtime...");
        await loadRuntimeScript(indexURL);

        const pyodide = await loadPyodide({ indexURL: indexURL });
        state.pyodide = pyodide;

        stdoutWriter = makeWriter("stdout");
        stderrWriter = makeWriter("stderr");
        pyodide.setStdout(stdoutWriter);
        pyodide.setStderr(stderrWriter);
        pyodide.setStdin({
          stdin: function () {
            const value = nativeInput("");
            return value === null ? null : value + "\n";
          },
          isatty: false,
        });
        // The Python shim calls this directly so it can print the prompt and
        // raise Python's own EOFError when the native panel is cancelled.
        pyodide.globals.set("_spyder_native_input", nativeInput);

        status("Installing " + packages.join(", ") + "...");
        await pyodide.loadPackage(packages, {
          messageCallback: function (message) { status(message); },
          errorCallback: function (message) { console.warn("[spyder] package", message); },
        });

        status("Configuring Matplotlib...");
        await pyodide.runPythonAsync(pythonInitSource(state.dpi));

        state.booted = true;
        state.booting = false;
        state.packages = packages;
        post({ type: "ready", version: pyodide.version, packages: packages });
        return;
      } catch (error) {
        lastError = error;
        state.pyodide = null;
        console.error("[spyder] boot attempt failed", indexURL, error);
      }
    }

    state.booting = false;
    post({
      type: "failure",
      message: "Pyodide could not start. " + describeError(lastError),
    });
  }

  // MARK: Workspace

  function readWorkspace() {
    // pyodide.globals is a PyProxy for a Python dict. Deep-converting it
    // directly would deep-copy ndarrays and leak function/module proxies, so
    // we build a JSON-safe projection in Python and run it through toJs().
    const proxy = state.pyodide.runPython("_spyder_workspace()");
    try {
      const converted = proxy.toJs({ dict_converter: Object.fromEntries, depth: 4 });
      if (converted instanceof Map) {
        return Object.fromEntries(converted);
      }
      return converted || { variables: [] };
    } finally {
      proxy.destroy();
    }
  }

  // MARK: Execution

  async function execute(request) {
    const id = String((request && request.id) || "");
    const code = String((request && request.code) || "");

    if (!state.pyodide || !state.booted) {
      post({
        type: "result",
        id: id,
        ok: false,
        durationMs: 0,
        variables: [],
        plots: [],
        error: "Python is not ready yet.",
      });
      return;
    }

    if (state.running) {
      post({
        type: "result",
        id: id,
        ok: false,
        durationMs: 0,
        variables: [],
        plots: [],
        error: "A cell is already running.",
      });
      return;
    }

    state.running = true;
    const startedAt = performance.now();
    let errorText = null;

    try {
      await state.pyodide.runPythonAsync(code, { filename: "<spyder-cell>" });
    } catch (error) {
      errorText = describeError(error);
    }

    flushOutputStreams();

    let plots = [];
    try {
      const plotsProxy = state.pyodide.runPython("_spyder_take_plots()");
      try {
        plots = plotsProxy.toJs({ dict_converter: Object.fromEntries, depth: 3 });
      } finally {
        plotsProxy.destroy();
      }
    } catch (error) {
      console.error("[spyder] plot capture failed", error);
    }

    let workspace = { variables: [] };
    try {
      workspace = readWorkspace();
    } catch (error) {
      console.error("[spyder] workspace snapshot failed", error);
    }

    state.running = false;
    const payload = {
      type: "result",
      id: id,
      ok: errorText === null,
      durationMs: Math.round(performance.now() - startedAt),
      variables: workspace.variables || [],
      count: workspace.count || 0,
      plots: plots || [],
    };
    if (errorText !== null) { payload.error = errorText; }
    post(payload);
  }

  function refresh(request) {
    const id = String((request && request.id) || "");
    if (!state.pyodide || !state.booted) { return; }

    let variables = [];
    try {
      variables = readWorkspace().variables || [];
    } catch (error) {
      console.error("[spyder] workspace refresh failed", error);
    }
    post({ type: "workspace", id: id, variables: variables });
  }

  // MARK: Variable inspection

  const IDENTIFIER_PATTERN = /^[A-Za-z_][A-Za-z0-9_]*$/;
  const DOTTED_PATTERN = /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$/;

  function previewVariable(request) {
    const id = String((request && request.id) || "");
    const name = String((request && request.name) || "");
    const pyodide = state.pyodide;

    if (!pyodide || !state.booted) {
      post({ type: "preview", id: id, preview: { name: name, error: "Python is not ready yet." } });
      return;
    }
    if (!IDENTIFIER_PATTERN.test(name)) {
      post({ type: "preview", id: id, preview: { name: name, error: "Invalid variable name." } });
      return;
    }

    try {
      pyodide.globals.set("_spyder_target_name", name);
      const proxy = pyodide.runPython("_spyder_inspect(_spyder_target_name)");
      let payload;
      try {
        payload = proxy.toJs({ dict_converter: Object.fromEntries, depth: 5 });
      } finally {
        proxy.destroy();
      }
      if (payload instanceof Map) {
        payload = Object.fromEntries(payload);
      }
      if (!payload) {
        payload = { name: name, error: "Empty preview." };
      }
      post({ type: "preview", id: id, preview: payload });
    } catch (error) {
      post({ type: "preview", id: id, preview: { name: name, error: describeError(error) } });
    } finally {
      try { pyodide.runPython("globals().pop('_spyder_target_name', None)"); } catch (error) { /* ignore */ }
    }
  }

  function documentSymbol(request) {
    const id = String((request && request.id) || "");
    const symbol = String((request && request.symbol) || "");
    const source = String((request && request.source) || "");
    const pyodide = state.pyodide;

    if (!pyodide || !state.booted) {
      post({ type: "help", id: id, help: { symbol: symbol, error: "Python is not ready yet." } });
      return;
    }
    if (!DOTTED_PATTERN.test(symbol)) {
      post({ type: "help", id: id, help: { symbol: symbol, error: "Invalid symbol name." } });
      return;
    }

    try {
      pyodide.globals.set("_spyder_help_name", symbol);
      pyodide.globals.set("_spyder_help_source", source);
      const proxy = pyodide.runPython("_spyder_help(_spyder_help_name, _spyder_help_source)");
      let payload;
      try {
        payload = proxy.toJs({ dict_converter: Object.fromEntries, depth: 3 });
      } finally {
        proxy.destroy();
      }
      if (payload instanceof Map) {
        payload = Object.fromEntries(payload);
      }
      post({ type: "help", id: id, help: payload || { symbol: symbol, error: "Empty result." } });
    } catch (error) {
      post({ type: "help", id: id, help: { symbol: symbol, error: describeError(error) } });
    } finally {
      try { pyodide.runPython("globals().pop('_spyder_help_name', None)"); } catch (error) { /* ignore */ }
      try { pyodide.runPython("globals().pop('_spyder_help_source', None)"); } catch (error) { /* ignore */ }
    }
  }

  function deleteVariable(request) {
    const id = String((request && request.id) || "");
    const name = String((request && request.name) || "");
    const pyodide = state.pyodide;
    let removed = false;

    if (pyodide && state.booted && IDENTIFIER_PATTERN.test(name)) {
      try {
        pyodide.globals.set("_spyder_delete_name", name);
        removed = Boolean(pyodide.runPython("_spyder_delete(_spyder_delete_name)"));
      } catch (error) {
        console.error("[spyder] delete failed", error);
      } finally {
        try { pyodide.runPython("globals().pop('_spyder_delete_name', None)"); } catch (error) { /* ignore */ }
      }
    }

    post({ type: "variableDeleted", id: id, name: name, removed: removed });
    refresh({ id: id });
  }

  // MARK: Workspace files

  function workspaceDirectory(pyodide) {
    try {
      return String(pyodide.runPython("import os; os.getcwd()"));
    } catch (error) {
      return "/home/pyodide";
    }
  }

  function sanitizeFileName(value) {
    const raw = String(value || "");
    if (!raw || raw.indexOf("\u0000") !== -1) { return null; }
    const name = raw.split("/").pop().split("\\").pop();
    if (!name || name === "." || name === "..") { return null; }
    return name;
  }

  function base64ToBytes(base64) {
    const binary = atob(String(base64 || ""));
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) {
      bytes[index] = binary.charCodeAt(index);
    }
    return bytes;
  }

  function bytesToBase64(bytes) {
    let binary = "";
    const chunk = 0x8000;
    for (let index = 0; index < bytes.length; index += chunk) {
      binary += String.fromCharCode.apply(null, bytes.subarray(index, index + chunk));
    }
    return btoa(binary);
  }

  function listFiles(request) {
    const id = String((request && request.id) || "");
    const pyodide = state.pyodide;

    if (!pyodide || !state.booted) {
      post({ type: "files", id: id, files: [], error: "Python is not ready yet." });
      return;
    }

    try {
      const proxy = pyodide.runPython("_spyder_list_files()");
      let payload;
      try {
        payload = proxy.toJs({ dict_converter: Object.fromEntries, depth: 3 });
      } finally {
        proxy.destroy();
      }
      if (payload instanceof Map) { payload = Object.fromEntries(payload); }
      post({ type: "files", id: id, files: (payload && payload.files) || [] });
    } catch (error) {
      post({ type: "files", id: id, files: [], error: describeError(error) });
    }
  }

  function writeFile(request) {
    const id = String((request && request.id) || "");
    const name = sanitizeFileName(request && request.name);
    const pyodide = state.pyodide;

    if (!pyodide || !state.booted) {
      post({ type: "fileOperation", id: id, name: name || "", ok: false, error: "Python is not ready yet." });
      return;
    }
    if (!name) {
      post({ type: "fileOperation", id: id, name: "", ok: false, error: "Invalid file name." });
      return;
    }

    try {
      const bytes = base64ToBytes(request && request.base64);
      pyodide.FS.writeFile(workspaceDirectory(pyodide) + "/" + name, bytes);
      post({ type: "fileOperation", id: id, name: name, ok: true, size: bytes.length });
    } catch (error) {
      post({ type: "fileOperation", id: id, name: name, ok: false, error: describeError(error) });
    }
  }

  function readFile(request) {
    const id = String((request && request.id) || "");
    const name = sanitizeFileName(request && request.name);
    const pyodide = state.pyodide;

    if (!pyodide || !state.booted) {
      post({ type: "fileData", id: id, name: name || "", base64: "", size: 0, error: "Python is not ready yet." });
      return;
    }
    if (!name) {
      post({ type: "fileData", id: id, name: "", base64: "", size: 0, error: "Invalid file name." });
      return;
    }

    try {
      const bytes = pyodide.FS.readFile(workspaceDirectory(pyodide) + "/" + name);
      post({ type: "fileData", id: id, name: name, base64: bytesToBase64(bytes), size: bytes.length });
    } catch (error) {
      post({ type: "fileData", id: id, name: name, base64: "", size: 0, error: describeError(error) });
    }
  }

  function deleteFile(request) {
    const id = String((request && request.id) || "");
    const name = sanitizeFileName(request && request.name);
    const pyodide = state.pyodide;

    if (!pyodide || !state.booted) {
      post({ type: "fileOperation", id: id, name: name || "", ok: false, error: "Python is not ready yet." });
      return;
    }
    if (!name) {
      post({ type: "fileOperation", id: id, name: "", ok: false, error: "Invalid file name." });
      return;
    }

    try {
      pyodide.FS.unlink(workspaceDirectory(pyodide) + "/" + name);
      post({ type: "fileOperation", id: id, name: name, ok: true });
    } catch (error) {
      post({ type: "fileOperation", id: id, name: name, ok: false, error: describeError(error) });
    }
  }

  function clearVariables(request) {
    const id = String((request && request.id) || "");
    const pyodide = state.pyodide;
    let removed = 0;

    if (pyodide && state.booted) {
      try {
        removed = Number(pyodide.runPython("_spyder_clear_workspace()")) || 0;
      } catch (error) {
        console.error("[spyder] clear workspace failed", error);
      }
      post({ type: "variablesCleared", id: id, count: removed });
      refresh({ id: id });
    } else {
      post({ type: "variablesCleared", id: id, count: 0 });
    }
  }

  // MARK: Public surface

  bridge.boot = function (configuration) {
    boot(configuration);
  };

  bridge.execute = function (request) {
    execute(request);
  };

  bridge.refresh = function (request) {
    refresh(request);
  };

  bridge.preview = function (request) {
    previewVariable(request);
  };

  bridge.help = function (request) {
    documentSymbol(request);
  };

  bridge.deleteVariable = function (request) {
    deleteVariable(request);
  };

  bridge.clearVariables = function (request) {
    clearVariables(request);
  };

  bridge.listFiles = function (request) {
    listFiles(request);
  };

  bridge.writeFile = function (request) {
    writeFile(request);
  };

  bridge.readFile = function (request) {
    readFile(request);
  };

  bridge.deleteFile = function (request) {
    deleteFile(request);
  };

  bridge.isReady = function () {
    return state.booted;
  };

  window.addEventListener("error", function (event) {
    post({ type: "log", message: "JavaScript error: " + describeError(event.error || event.message) });
  });

  window.addEventListener("unhandledrejection", function (event) {
    post({ type: "log", message: "JavaScript rejection: " + describeError(event.reason) });
  });

  // Signal that the bridge object exists even before Pyodide loads.
  post({ type: "status", phase: "bridge", detail: "Bridge ready" });
})();

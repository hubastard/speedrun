// speedrun's JavaScript engine: QuickJS-ng (quickjs-ng/, v0.17.0) behind a small C API for
// the Odin host (host/js.odin). What scripts see is set up by prelude.js; this file creates
// the engine, hands prelude.js its natives (log, http) and calls the object it returns.
// build.sh compiles it with QuickJS-ng into js/build/libspeedrunjs.a.
#include <stdlib.h>
#include <string.h>

#include "quickjs-ng/quickjs.h"

// A console line from a script.
typedef void (*sr_log_fn)(void *user, const char *msg, size_t len);
// An HTTP request as JSON; returns the reply as JSON, malloc'd and NUL-terminated.
typedef char *(*sr_http_fn)(void *user, const char *request, size_t len);

typedef struct sr_js {
	JSRuntime *rt;
	JSContext *ctx;
	JSValue api; // what prelude.js returns: {run, setEnv, setCopiedText}
	sr_log_fn log;
	sr_http_fn http;
	void *user;
} sr_js;

static char *copy_out(const char *s, size_t len, size_t *out_len) {
	char *out = malloc(len + 1);
	if (!out) return NULL;
	memcpy(out, s, len);
	out[len] = 0;
	if (out_len) *out_len = len;
	return out;
}

// A value as text, malloc'd: String(value), or a placeholder when that throws.
static char *value_text(JSContext *ctx, JSValueConst v, size_t *out_len) {
	size_t len;
	const char *s = JS_ToCStringLen(ctx, &len, v);
	if (!s) {
		JS_FreeValue(ctx, JS_GetException(ctx));
		return copy_out("(a value that cannot be shown)", 30, out_len);
	}
	char *out = copy_out(s, len, out_len);
	JS_FreeCString(ctx, s);
	return out;
}

// The pending exception's message ("TypeError: not a function"), malloc'd.
static char *exception_text(JSContext *ctx, size_t *out_len) {
	JSValue ex = JS_GetException(ctx);
	char *out = value_text(ctx, ex, out_len);
	JS_FreeValue(ctx, ex);
	return out;
}

static JSValue native_log(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
	(void)this_val;
	sr_js *e = JS_GetContextOpaque(ctx);
	if (argc < 1) return JS_UNDEFINED;
	size_t len;
	const char *s = JS_ToCStringLen(ctx, &len, argv[0]);
	if (!s) return JS_EXCEPTION;
	e->log(e->user, s, len);
	JS_FreeCString(ctx, s);
	return JS_UNDEFINED;
}

static JSValue native_http(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
	(void)this_val;
	sr_js *e = JS_GetContextOpaque(ctx);
	if (argc < 1) return JS_ThrowTypeError(ctx, "http: no request");
	size_t len;
	const char *s = JS_ToCStringLen(ctx, &len, argv[0]);
	if (!s) return JS_EXCEPTION;
	char *reply = e->http(e->user, s, len);
	JS_FreeCString(ctx, s);
	if (!reply) return JS_ThrowInternalError(ctx, "http: no reply");
	JSValue v = JS_NewString(ctx, reply);
	free(reply);
	return v;
}

void sr_js_free(sr_js *e) {
	if (!e) return;
	if (e->ctx) {
		JS_FreeValue(e->ctx, e->api);
		JS_FreeContext(e->ctx);
	}
	if (e->rt) JS_FreeRuntime(e->rt);
	free(e);
}

// A new engine with prelude.js evaluated. NULL on failure, with *err (malloc'd) saying why.
sr_js *sr_js_new(const char *prelude, size_t prelude_len, const char *platform, sr_log_fn log,
                 sr_http_fn http, void *user, char **err) {
	*err = NULL;
	sr_js *e = calloc(1, sizeof *e);
	if (!e) return NULL;
	e->api = JS_UNDEFINED;
	e->log = log;
	e->http = http;
	e->user = user;
	e->rt = JS_NewRuntime();
	e->ctx = e->rt ? JS_NewContext(e->rt) : NULL;
	if (!e->ctx) {
		*err = copy_out("cannot create a JavaScript engine", 33, NULL);
		sr_js_free(e);
		return NULL;
	}
	JSContext *ctx = e->ctx;
	JS_SetContextOpaque(ctx, e);

	// JS_Eval needs its input NUL-terminated.
	char *src = copy_out(prelude, prelude_len, NULL);
	JSValue fn = JS_Eval(ctx, src, prelude_len, "prelude.js", JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_STRICT);
	free(src);
	if (JS_IsException(fn)) {
		*err = exception_text(ctx, NULL);
		sr_js_free(e);
		return NULL;
	}
	JSValue natives = JS_NewObject(ctx);
	JS_SetPropertyStr(ctx, natives, "log", JS_NewCFunction(ctx, native_log, "log", 1));
	JS_SetPropertyStr(ctx, natives, "http", JS_NewCFunction(ctx, native_http, "http", 1));
	JS_SetPropertyStr(ctx, natives, "platform", JS_NewString(ctx, platform));
	e->api = JS_Call(ctx, fn, JS_UNDEFINED, 1, (JSValueConst *)&natives);
	JS_FreeValue(ctx, natives);
	JS_FreeValue(ctx, fn);
	if (JS_IsException(e->api)) {
		*err = exception_text(ctx, NULL);
		e->api = JS_UNDEFINED;
		sr_js_free(e);
		return NULL;
	}
	return e;
}

// Calls api[method](arg). *out (malloc'd, NUL-terminated) is String(result), or the error's
// message when the call threw (then returns 1; 0 otherwise). Promise jobs the call queued
// run before it returns.
int sr_js_call(sr_js *e, const char *method, const char *arg, size_t arg_len, char **out, size_t *out_len) {
	JSContext *ctx = e->ctx;
	JSValue fn = JS_GetPropertyStr(ctx, e->api, method);
	JSValue a = JS_NewStringLen(ctx, arg, arg_len);
	JSValue r = JS_Call(ctx, fn, e->api, 1, (JSValueConst *)&a);
	JS_FreeValue(ctx, a);
	JS_FreeValue(ctx, fn);
	int failed = JS_IsException(r);
	*out = failed ? exception_text(ctx, out_len) : value_text(ctx, r, out_len);
	JS_FreeValue(ctx, r);
	JSContext *job_ctx;
	while (JS_ExecutePendingJob(e->rt, &job_ctx) != 0) {
		if (JS_HasException(job_ctx)) JS_FreeValue(job_ctx, JS_GetException(job_ctx));
	}
	return failed;
}

void sr_js_free_text(char *s) {
	free(s);
}

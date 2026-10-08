// state.v is the V transpile of
// ../once-campfire-python/src/campfile/state.py: per-request accessors.
//
// python keeps a shared engine in the Flask app and one Session in each
// request's flask.g. V's database.DB already holds a reader pool and a
// single writer, so the equivalent of "the session for this request" is
// Ctx: the shared DB handle plus the user resolved by before_request.
module campfile

// There is no Ctx struct: the equivalent of "the session for this request"
// is the `mut db database.DB` argument every handler takes plus the user id
// that before_request resolves into Req.user_id. database.DB already holds
// a reader pool and a single writer, so sharing one handle across requests
// is exactly what python's shared engine plus per-request Session does.

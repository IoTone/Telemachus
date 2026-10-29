// ---- boot --------------------------------------------------------------------
// The one call that starts the console, in a file of its own so that it is the
// LAST thing the browser runs.
//
// It used to be the last line of 13-kg.js, which worked only because `render()`
// is async and yields at its first `await` — giving the remaining <script> tags
// time to parse before it reached the dispatch table in `renderTab()`. That is
// a real dependency on a detail of the event loop, and it breaks the moment a
// new view is added in a file that sorts after the one that boots: the tab
// exists, the function does not, and the console dies with a ReferenceError at
// load. #179 added the first such file.
//
// The name sorts after every numbered one, which is what test/console-tests.rkt
// requires of the load order (the shell's <script> tags must equal the directory
// listing in name order, in both directions).
render();

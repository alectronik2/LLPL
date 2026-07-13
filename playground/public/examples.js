// A handful of self-contained snippets for the playground's example
// picker - kept short and hosted-runnable (no bare-metal/asm-only
// features), showing off a spread of language features.
var LLPL_EXAMPLES = {
    'Hello, world': `extern func puts(s: char*) -> int

func main() -> int {
    puts("Hello from LLPL!")
    return 0
}
`,

    'Classes & methods': `extern func puts(s: char*) -> int

class Rectangle {
    let width: int
    let height: int

    constructor(w: int, h: int) {
        self.width = w
        self.height = h
    }
    destructor() {}

    func area() -> int {
        return self.width * self.height
    }
}

func main() -> int {
    let r: Rectangle = new Rectangle(6, 7)
    puts("area = \\(r.area())")
    return 0
}
`,

    'If-expressions & implicit returns': `extern func puts(s: char*) -> int

func classify(n: int) -> char* {
    // Parens make this an if-*expression* whose value is the function's
    // implicit return - a bare, unparenthesized if here would instead
    // parse as an if-statement with no return at all.
    (if n < 0 {
        "negative"
    } else if n == 0 {
        "zero"
    } else {
        "positive"
    })
}

func main() -> int {
    let x: int = if true { 128 } else { 256 }
    puts(classify(x))
    puts(classify(-5))
    puts(classify(0))
    return 0
}
`,

    'Iterators & for-loops': `extern func puts(s: char*) -> int

class Countdown {
    let n: int
    constructor(n: int) { self.n = n }
    destructor() {}
}

impl Iterator<int> for Countdown {
    func iter_has_next() -> bool {
        return self.n > 0
    }
    func iter_next() -> int {
        self.n = self.n - 1
        return self.n + 1
    }
}

func main() -> int {
    for x in new Countdown(5) {
        puts("x = \\(x)")
    }
    for i in 0..3 {
        puts("range i = \\(i)")
    }
    return 0
}
`,

    'Result<T, E> and ?': `extern func puts(s: char*) -> int

func safe_div(a: int, b: int) -> Result<int, char*> {
    let r: Result<int, char*> = new Result<int, char*>()
    if b == 0 {
        r.set_err("division by zero")
        return r
    }
    r.set_ok(a / b)
    return r
}

// \`?\` unwraps a Result - returns early with the same error if it
// failed, otherwise evaluates to the Ok value.
func compute() -> Result<int, char*> {
    let a: int = safe_div(10, 2)?
    let b: int = safe_div(a, 0)?
    let out: Result<int, char*> = new Result<int, char*>()
    out.set_ok(b)
    return out
}

func main() -> int {
    let result: Result<int, char*> = compute()
    if result.is_ok() {
        puts("ok")
    } else {
        puts(result.get_err())
    }
    return 0
}
`,
};

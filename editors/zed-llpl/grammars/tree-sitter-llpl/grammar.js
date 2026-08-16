const IDENT = /[A-Za-z_][A-Za-z0-9_]*/;

module.exports = grammar({
  name: "llpl",

  word: ($) => $.identifier,

  extras: ($) => [/\s/, $.line_comment, $.block_comment],

  rules: {
    source_file: ($) => repeat($._item),

    _item: ($) =>
      choice(
        $.compiler_directive,
        $.import_declaration,
        $.namespace_declaration,
        $.using_declaration,
        $.function_declaration,
        $.macro_declaration,
        $.unittest_declaration,
        $.class_declaration,
        $.struct_declaration,
        $.union_declaration,
        $.enum_declaration,
        $.trait_declaration,
        $.impl_declaration,
        $.ui_declaration,
        $.alias_declaration,
        $.variable_declaration,
        $.statement,
        $.block
      ),

    line_comment: (_) => token(seq("//", /.*/)),
    block_comment: (_) => token(seq("/*", /[^*]*\*+([^/*][^*]*\*+)*/, "/")),

    compiler_directive: ($) => seq("#", field("name", $.identifier), optional($.string_literal)),

    import_declaration: ($) =>
      seq(
        "import",
        choice($.string_literal, $.qualified_identifier),
        optional(seq("as", $.identifier)),
        optional(";")
      ),

    namespace_declaration: ($) => seq("namespace", field("name", $.identifier), optional($.block)),

    using_declaration: ($) =>
      seq("using", optional("namespace"), $.qualified_identifier, optional(";")),

    function_declaration: ($) =>
      seq(
        repeat($.modifier),
        "func",
        field("name", choice($.identifier, $.operator_name)),
        optional($.type_parameters),
        optional($.parameter_list),
        optional(seq(choice("->", ":"), $._type)),
        optional($.block)
      ),

    macro_declaration: ($) =>
      seq("macro", field("name", $.identifier), optional($.parameter_list), optional($.block)),

    unittest_declaration: ($) =>
      seq("unittest", optional(field("name", $.identifier)), optional($.block)),

    class_declaration: ($) =>
      seq(
        repeat($.modifier),
        "class",
        field("name", $.identifier),
        optional(seq(":", $.qualified_identifier)),
        optional($.block)
      ),

    struct_declaration: ($) =>
      seq(repeat($.modifier), "struct", field("name", $.identifier), optional($.block)),

    union_declaration: ($) =>
      seq(repeat($.modifier), "union", field("name", $.identifier), optional($.block)),

    enum_declaration: ($) =>
      seq("enum", field("name", $.identifier), optional(seq(":", $._type)), optional($.block)),

    trait_declaration: ($) =>
      seq("trait", field("name", $.identifier), optional($.block)),

    impl_declaration: ($) =>
      seq("impl", field("name", $.qualified_identifier), optional($.block)),

    ui_declaration: ($) =>
      seq("ui", field("name", $.identifier), optional(seq(":", $.qualified_identifier)), optional($.block)),

    alias_declaration: ($) =>
      seq("alias", field("name", $.identifier), optional(seq("=", $._type)), optional(";")),

    variable_declaration: ($) =>
      seq(
        repeat($.modifier),
        choice("let", "const"),
        field("name", $.identifier),
        optional(seq(":", $._type)),
        optional(seq("=", $._expression)),
        optional(";")
      ),

    parameter_list: ($) => seq("(", optional(commaSep($.parameter)), ")"),
    parameter: ($) => seq(optional($.identifier), optional(seq(":", $._type))),

    type_parameters: ($) => seq("<", commaSep1($.identifier), ">"),

    block: ($) => seq("{", repeat($._item), "}"),

    statement: ($) =>
      seq(
        choice(
          $.return_statement,
          $.if_statement,
          $.while_statement,
          $.for_statement,
          $.expression_statement
        ),
        optional(";")
      ),

    return_statement: ($) => seq("return", optional($._expression)),
    if_statement: ($) => seq("if", $._expression, optional($.block), optional(seq("else", choice($.block, $.if_statement)))),
    while_statement: ($) => seq("while", $._expression, optional($.block)),
    for_statement: ($) => seq(choice("for", "foreach"), $.identifier, optional(seq("in", $._expression)), optional($.block)),
    expression_statement: ($) => $._expression,

    _expression: ($) =>
      choice(
        $.call_expression,
        $.member_expression,
        $.qualified_identifier,
        $.identifier,
        $.number,
        $.string_literal,
        $.char_literal,
        $.unknown_token
      ),

    call_expression: ($) => prec(2, seq(field("function", choice($.member_expression, $.qualified_identifier, $.identifier)), $.argument_list)),
    member_expression: ($) => prec(1, seq(choice($.qualified_identifier, $.identifier), ".", field("property", $.identifier))),
    argument_list: ($) => seq("(", optional(commaSep($._expression)), ")"),

    _type: ($) =>
      seq(
        choice($.qualified_identifier, $.identifier),
        repeat(choice("*", "[]", seq("[", optional($.number), "]")))
      ),

    qualified_identifier: ($) => seq($.identifier, repeat1(seq(".", $.identifier))),
    identifier: (_) => token(IDENT),
    operator_name: (_) => token(seq("operator", /==|!=|<=|>=|<<|>>|[+\-*\/%=<>!&|^~]/)),

    modifier: (_) =>
      choice(
        "inline",
        "private",
        "static",
        "virtual",
        "override",
        "extern",
        "volatile",
        "packed",
        "interrupt",
        "property"
      ),

    string_literal: ($) =>
      seq('"', repeat(choice($.escape_sequence, token.immediate(/[^"\\]+/))), '"'),

    char_literal: ($) =>
      seq("'", choice($.escape_sequence, token.immediate(/[^'\\]/)), "'"),

    escape_sequence: (_) => token.immediate(seq("\\", choice(/[nrt0\\"'e]/, seq("x", /[0-9a-fA-F]{1,2}/)))),

    number: (_) =>
      token(
        choice(
          /0[xX][0-9a-fA-F_]+/,
          /0[bB][01_]+/,
          /0[oO][0-7_]+/,
          /[0-9][0-9_]*(\.[0-9_]+)?([eE][+-]?[0-9_]+)?[fFdD]?/
        )
      ),

    unknown_token: (_) => token(/[^{}\[\]();,\s"']+/),
  },
});

function commaSep(rule) {
  return optional(commaSep1(rule));
}

function commaSep1(rule) {
  return seq(rule, repeat(seq(",", rule)), optional(","));
}

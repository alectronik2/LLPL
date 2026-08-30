#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include "runtime.h"

// Monomorphized generic instantiations - forward declarations
uint64_t i64_hash(int64_t self);
bool i64_equals(int64_t self, int64_t other);
uint64_t u64_hash(uint64_t self);
bool u64_equals(uint64_t self, uint64_t other);
uint64_t u8_hash(uint8_t self);
bool u8_equals(uint8_t self, uint8_t other);
uint64_t char_ptr_hash(char* self);
bool char_ptr_equals(char* self, char* other);
typedef struct String String;
uint64_t String_hash(String* self);
typedef struct String String;
bool String_equals(String* self, String* other);
int64_t i64_compare(int64_t self, int64_t other);
int64_t u64_compare(uint64_t self, uint64_t other);
int64_t u8_compare(uint8_t self, uint8_t other);
bool char_ptr_op_eq(char* self, char* other);
bool char_ptr_op_ne(char* self, char* other);
bool char_ptr_op_lt(char* self, char* other);
bool char_ptr_op_gt(char* self, char* other);
bool char_ptr_op_le(char* self, char* other);
bool char_ptr_op_ge(char* self, char* other);
typedef struct Vector_ParseNode Vector_ParseNode;
typedef struct ParseNode ParseNode;
Vector_ParseNode* Vector_ParseNode_new();
Vector_ParseNode* Vector_ParseNode_new_i64_ParseNode(int64_t count, ParseNode* value);
void Vector_ParseNode_destroy(void* ptr);
void Vector_ParseNode_push(Vector_ParseNode* self, ParseNode* item);
void Vector_ParseNode_grow(Vector_ParseNode* self);
ParseNode* Vector_ParseNode_get(Vector_ParseNode* self, int64_t index);
void Vector_ParseNode_set(Vector_ParseNode* self, int64_t index, ParseNode* item);
ParseNode* Vector_ParseNode_pop(Vector_ParseNode* self);
int64_t Vector_ParseNode_len(Vector_ParseNode* self);
bool Vector_ParseNode_is_empty(Vector_ParseNode* self);
void Vector_ParseNode_push_back(Vector_ParseNode* self, ParseNode* item);
ParseNode* Vector_ParseNode_pop_back(Vector_ParseNode* self);
int64_t Vector_ParseNode_size(Vector_ParseNode* self);
bool Vector_ParseNode_empty(Vector_ParseNode* self);
void Vector_ParseNode_clear(Vector_ParseNode* self);
void Vector_ParseNode_reserve(Vector_ParseNode* self, int64_t n);
void Vector_ParseNode_resize(Vector_ParseNode* self, int64_t n, ParseNode* value);
ParseNode* Vector_ParseNode_front(Vector_ParseNode* self);
ParseNode* Vector_ParseNode_back(Vector_ParseNode* self);
ParseNode* Vector_ParseNode_at(Vector_ParseNode* self, int64_t index);
ParseNode* Vector_ParseNode_op_index(Vector_ParseNode* self, int64_t index);
void Vector_ParseNode_op_index_set(Vector_ParseNode* self, int64_t index, ParseNode* value);
ParseNode* Vector_ParseNode_data(Vector_ParseNode* self);
int64_t Vector_ParseNode_capacity(Vector_ParseNode* self);
typedef struct Slice_ParseNode Slice_ParseNode;
typedef struct ParseNode ParseNode;
Slice_ParseNode Vector_ParseNode_as_slice(Vector_ParseNode* self);
typedef struct Slice_char Slice_char;

typedef struct EmbeddedFile EmbeddedFile;
typedef struct ReflectField ReflectField;
typedef struct ReflectType ReflectType;
typedef struct RegexMatch RegexMatch;
typedef struct RegexMatchIterator RegexMatchIterator;
typedef struct Regex Regex;
typedef struct String String;
typedef struct OwnedBuffer OwnedBuffer;
typedef struct ParseNode ParseNode;

extern int64_t ksnprintf(char* buf, uint64_t size, char* fmt, ...);
extern int64_t puts(char* s);
extern void llpl_panic(char* msg);
extern uint64_t llpl_strlen(char* s);
extern int64_t llpl_strcmp(char* a, char* b);
extern bool llpl_utf8_valid(char* s);
extern uint64_t llpl_utf8_len(char* s);
extern uint64_t llpl_utf8_byte_offset(char* s, uint64_t char_index);
extern uint64_t llpl_utf8_char_index(char* s, uint64_t byte_offset);
extern uint64_t llpl_utf8_codepoint_at(char* s, uint64_t char_index);
extern bool llpl_regex_match(char* pattern, char* text);
extern uint64_t llpl_regex_group_count(char* pattern);
extern bool llpl_regex_capture_bounds(char* pattern, char* text, uint64_t group, int64_t* start, int64_t* end);
extern char* llpl_regex_capture(char* pattern, char* text, uint64_t group);
extern char* llpl_reflect_type(char* name);
extern char* llpl_reflect_type_name(char* type);
extern char* llpl_reflect_type_kind(char* type);
extern uint64_t llpl_reflect_type_size(char* type);
extern uint64_t llpl_reflect_field_count(char* type);
extern char* llpl_reflect_field(char* type, uint64_t index);
extern char* llpl_reflect_field_name(char* field);
extern char* llpl_reflect_field_type_name(char* field);
extern uint64_t llpl_reflect_field_offset(char* field);
extern uint64_t llpl_reflect_field_size(char* field);
extern char* llpl_alloc(uint64_t size);
extern void llpl_free(char* ptr);
extern void llpl_memcpy(char* dest, char* src, uint64_t count);
extern void rc_retain(char* ptr);
extern void rc_weak_retain(char* ptr);
extern void rc_weak_release(char* ptr);
extern bool rc_is_alive(char* ptr);
extern char* llpl_resolve_symbol(uint64_t addr);
extern char* llpl_symbol_name(char* symbol);
extern char* llpl_symbol_file(char* symbol);
extern int64_t llpl_symbol_line(char* symbol);
extern void llpl_panic_backtrace();
extern void llpl_panic(char* msg);
extern void* __llpl_check_index(void* arr, int64_t idx, int64_t size, uint64_t elem_size);
ReflectField* ReflectField_new(char* raw);
void ReflectField_destroy(void* ptr);
bool ReflectField_exists(ReflectField* self);
char* ReflectField_name(ReflectField* self);
char* ReflectField_type_name(ReflectField* self);
int64_t ReflectField_offset(ReflectField* self);
int64_t ReflectField_size(ReflectField* self);
ReflectType* ReflectType_new(char* raw);
void ReflectType_destroy(void* ptr);
bool ReflectType_exists(ReflectType* self);
char* ReflectType_name(ReflectType* self);
char* ReflectType_kind(ReflectType* self);
int64_t ReflectType_size(ReflectType* self);
int64_t ReflectType_field_count(ReflectType* self);
ReflectField* ReflectType_field(ReflectType* self, int64_t index);
RegexMatch* RegexMatch_new(char* pattern, char* text, int64_t base_offset);
void RegexMatch_destroy(void* ptr);
bool RegexMatch_is_match(RegexMatch* self);
int64_t RegexMatch_group_count(RegexMatch* self);
bool RegexMatch_has_group(RegexMatch* self, int64_t index);
int64_t RegexMatch_group_start(RegexMatch* self, int64_t index);
int64_t RegexMatch_group_end(RegexMatch* self, int64_t index);
String* RegexMatch_group(RegexMatch* self, int64_t index);
String* RegexMatch_expand(RegexMatch* self, char* template);
RegexMatchIterator* RegexMatchIterator_new(char* pattern, char* text);
void RegexMatchIterator_destroy(void* ptr);
bool RegexMatchIterator_advance(RegexMatchIterator* self);
bool RegexMatchIterator_iter_has_next(RegexMatchIterator* self);
RegexMatch* RegexMatchIterator_iter_next(RegexMatchIterator* self);
Regex* Regex_new(char* pattern);
void Regex_destroy(void* ptr);
bool Regex_match(Regex* self, char* text);
RegexMatch* Regex_captures(Regex* self, char* text);
RegexMatchIterator* Regex_find_all(Regex* self, char* text);
String* Regex_replace(Regex* self, char* text, char* replacement);
String* Regex_replace_all(Regex* self, char* text, char* replacement);
char* Regex_source(Regex* self);
String* String_new(char* s);
void String_destroy(void* ptr);
int64_t String_byte_len(String* self);
int64_t String_len(String* self);
bool String_is_utf8(String* self);
int64_t String_byte_index(String* self, int64_t char_index);
int64_t String_char_index(String* self, int64_t byte_offset);
uint64_t String_codepoint_at(String* self, int64_t char_index);
char* String_c_str(String* self);
char String_byte_at(String* self, int64_t index);
uint64_t String_op_index(String* self, int64_t index);
void String_iter_reset(String* self);
bool String_iter_has_next(String* self);
uint64_t String_iter_next(String* self);
void String_byte_set(String* self, int64_t index, char value);
bool String_op_eq_char_ptr(String* self, char* other);
bool String_op_ne_char_ptr(String* self, char* other);
bool String_op_lt_char_ptr(String* self, char* other);
bool String_op_gt_char_ptr(String* self, char* other);
bool String_op_eq_String(String* self, String* other);
bool String_op_ne_String(String* self, String* other);
bool String_op_lt_String(String* self, String* other);
bool String_op_gt_String(String* self, String* other);
String* String_op_add(String* self, char* other);
String* String_byte_substring(String* self, int64_t start, int64_t count);
String* String_substring(String* self, int64_t start, int64_t count);
String* String_utf8_substring(String* self, int64_t start, int64_t count);
int64_t String_byte_find(String* self, char* needle);
int64_t String_find(String* self, char* needle);
bool String_contains(String* self, char* needle);
bool String_starts_with(String* self, char* prefix);
bool String_ends_with(String* self, char* suffix);
String* String_to_upper(String* self);
String* String_to_lower(String* self);
String* String_trim(String* self);
OwnedBuffer* OwnedBuffer_new(uint64_t size);
void OwnedBuffer_destroy(void* ptr);
void OwnedBuffer_free(OwnedBuffer* self);
char* OwnedBuffer_data(OwnedBuffer* self);
uint64_t OwnedBuffer_len(OwnedBuffer* self);
bool OwnedBuffer_is_null(OwnedBuffer* self);
char OwnedBuffer_byte_at(OwnedBuffer* self, uint64_t index);
void OwnedBuffer_set(OwnedBuffer* self, uint64_t index, char value);
Slice_char OwnedBuffer_as_slice(OwnedBuffer* self);
char* OwnedBuffer_take(OwnedBuffer* self);
ParseNode* ParseNode_new();
void ParseNode_destroy(void* ptr);
String* ParseNode_name(ParseNode* self);
String* ParseNode_text(ParseNode* self);
ParseNode* ParseNode_child(ParseNode* self, int64_t index);
int64_t ParseNode_child_count(ParseNode* self);
Window* DemoWindow_build();
int64_t main();



struct EmbeddedFile {
    char* data;
    uint64_t len;
};

struct ReflectField {
    RefCount ref_count;
    char* raw;
};


struct ReflectType {
    RefCount ref_count;
    char* raw;
};


struct RegexMatch {
    RefCount ref_count;
    bool matched;
    char* pattern;
    char* text;
    int64_t base_offset;
};


struct RegexMatchIterator {
    RefCount ref_count;
    char* pattern;
    char* text;
    int64_t text_len;
    int64_t pos;
    RegexMatch* current;
    bool has_current;
    bool done;
};


struct Regex {
    RefCount ref_count;
    char* pattern;
};


struct String {
    RefCount ref_count;
    char* buf;
    int64_t length;
    int64_t iter_pos;
};


struct OwnedBuffer {
    RefCount ref_count;
    char* ptr;
    uint64_t length;
};


struct ParseNode {
    RefCount ref_count;
    String* rule_name;
    String* text_val;
    Vector_ParseNode* children;
    bool is_terminal;
};


// Monomorphized struct instantiations
struct Slice_ParseNode {
    ParseNode** ptr;
    uint64_t len;
};
struct Slice_char {
    char* ptr;
    uint64_t len;
};

// Monomorphized class instantiations
struct Vector_ParseNode {
    RefCount ref_count;
    ParseNode** data;
    int64_t length;
    int64_t capacity;
};

Vector_ParseNode* Vector_ParseNode_new() {
    Vector_ParseNode* self = (Vector_ParseNode*)rc_alloc(sizeof(Vector_ParseNode));
    if (!self) return NULL;
    rc_init(&self->ref_count);

    self->length = 0;
    self->capacity = 4;
    self->data = ((ParseNode**)llpl_alloc((((uint64_t)self->capacity) * sizeof(ParseNode))));
    return self;
}

Vector_ParseNode* Vector_ParseNode_new_i64_ParseNode(int64_t count, ParseNode* value) {
    Vector_ParseNode* self = (Vector_ParseNode*)rc_alloc(sizeof(Vector_ParseNode));
    if (!self) return NULL;
    rc_init(&self->ref_count);

    if ((count > 0)) {
        self->length = count;
        self->capacity = count;
    } else {
        self->length = 0;
        self->capacity = 4;
    }
    self->data = ((ParseNode**)llpl_alloc((((uint64_t)self->capacity) * sizeof(ParseNode))));
#line 1032 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t i = 0;
    while ((i < self->length)) {
        self->data[i] = value;
        i = (i + 1);
    }
    return self;
}

void Vector_ParseNode_destroy(void* ptr) {
    Vector_ParseNode* self = (Vector_ParseNode*)ptr;
    llpl_free(((char*)self->data));
}

void Vector_ParseNode_push(Vector_ParseNode* self, ParseNode* item) {
    if ((self->length >= self->capacity)) {
        Vector_ParseNode_grow(self);
    }
    self->data[self->length] = item;
    self->length = (self->length + 1);
}

void Vector_ParseNode_grow(Vector_ParseNode* self) {
#line 1056 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t new_capacity = (self->capacity * 2);
#line 1057 "/home/nix/Claude/LLPL/prelude.llpl"
    ParseNode** new_data = ((ParseNode**)llpl_alloc((((uint64_t)new_capacity) * sizeof(ParseNode))));
    llpl_memcpy(((char*)new_data), ((char*)self->data), (((uint64_t)self->length) * sizeof(ParseNode)));
    llpl_free(((char*)self->data));
    self->data = new_data;
    self->capacity = new_capacity;
}

ParseNode* Vector_ParseNode_get(Vector_ParseNode* self, int64_t index) {
    if (((index < 0) || (index >= self->length))) {
        llpl_panic("Vector.get: index out of bounds");
    }
#line 1068 "/home/nix/Claude/LLPL/prelude.llpl"
    ParseNode* __llpl_ret30 = self->data[index];
    return __llpl_ret30;
}

void Vector_ParseNode_set(Vector_ParseNode* self, int64_t index, ParseNode* item) {
    if (((index < 0) || (index >= self->length))) {
        llpl_panic("Vector.set: index out of bounds");
    }
    self->data[index] = item;
}

ParseNode* Vector_ParseNode_pop(Vector_ParseNode* self) {
    self->length = (self->length - 1);
#line 1080 "/home/nix/Claude/LLPL/prelude.llpl"
    ParseNode* __llpl_ret31 = self->data[self->length];
    return __llpl_ret31;
}

int64_t Vector_ParseNode_len(Vector_ParseNode* self) {
#line 1084 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t __llpl_ret32 = self->length;
    return __llpl_ret32;
}

bool Vector_ParseNode_is_empty(Vector_ParseNode* self) {
#line 1088 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret33 = (self->length == 0);
    return __llpl_ret33;
}

void Vector_ParseNode_push_back(Vector_ParseNode* self, ParseNode* item) {
    Vector_ParseNode_push(self, item);
}

ParseNode* Vector_ParseNode_pop_back(Vector_ParseNode* self) {
#line 1107 "/home/nix/Claude/LLPL/prelude.llpl"
    ParseNode* __llpl_ret34 = Vector_ParseNode_pop(self);
    return __llpl_ret34;
}

int64_t Vector_ParseNode_size(Vector_ParseNode* self) {
#line 1111 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t __llpl_ret35 = self->length;
    return __llpl_ret35;
}

bool Vector_ParseNode_empty(Vector_ParseNode* self) {
#line 1115 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret36 = (self->length == 0);
    return __llpl_ret36;
}

void Vector_ParseNode_clear(Vector_ParseNode* self) {
    self->length = 0;
}

void Vector_ParseNode_reserve(Vector_ParseNode* self, int64_t n) {
    if ((n <= self->capacity)) {
#line 1131 "/home/nix/Claude/LLPL/prelude.llpl"
        return;
    }
#line 1133 "/home/nix/Claude/LLPL/prelude.llpl"
    ParseNode** new_data = ((ParseNode**)llpl_alloc((((uint64_t)n) * sizeof(ParseNode))));
    llpl_memcpy(((char*)new_data), ((char*)self->data), (((uint64_t)self->length) * sizeof(ParseNode)));
    llpl_free(((char*)self->data));
    self->data = new_data;
    self->capacity = n;
}

void Vector_ParseNode_resize(Vector_ParseNode* self, int64_t n, ParseNode* value) {
    if ((n < self->length)) {
        self->length = n;
#line 1150 "/home/nix/Claude/LLPL/prelude.llpl"
        return;
    }
    Vector_ParseNode_reserve(self, n);
    while ((self->length < n)) {
        self->data[self->length] = value;
        self->length = (self->length + 1);
    }
}

ParseNode* Vector_ParseNode_front(Vector_ParseNode* self) {
#line 1160 "/home/nix/Claude/LLPL/prelude.llpl"
    ParseNode* __llpl_ret37 = Vector_ParseNode_get(self, 0);
    return __llpl_ret37;
}

ParseNode* Vector_ParseNode_back(Vector_ParseNode* self) {
#line 1164 "/home/nix/Claude/LLPL/prelude.llpl"
    ParseNode* __llpl_ret38 = Vector_ParseNode_get(self, (self->length - 1));
    return __llpl_ret38;
}

ParseNode* Vector_ParseNode_at(Vector_ParseNode* self, int64_t index) {
#line 1168 "/home/nix/Claude/LLPL/prelude.llpl"
    ParseNode* __llpl_ret39 = Vector_ParseNode_get(self, index);
    return __llpl_ret39;
}

ParseNode* Vector_ParseNode_op_index(Vector_ParseNode* self, int64_t index) {
#line 1172 "/home/nix/Claude/LLPL/prelude.llpl"
    ParseNode* __llpl_ret40 = Vector_ParseNode_get(self, index);
    return __llpl_ret40;
}

void Vector_ParseNode_op_index_set(Vector_ParseNode* self, int64_t index, ParseNode* value) {
    Vector_ParseNode_set(self, index, value);
}

ParseNode* Vector_ParseNode_data(Vector_ParseNode* self) {
#line 1185 "/home/nix/Claude/LLPL/prelude.llpl"
    ParseNode* __llpl_ret41 = ((ParseNode*)self->data);
    return __llpl_ret41;
}

int64_t Vector_ParseNode_capacity(Vector_ParseNode* self) {
#line 1189 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t __llpl_ret42 = self->capacity;
    return __llpl_ret42;
}

Slice_ParseNode Vector_ParseNode_as_slice(Vector_ParseNode* self) {
#line 1199 "/home/nix/Claude/LLPL/prelude.llpl"
    Slice_ParseNode __llpl_ret43 = (Slice_ParseNode){ .ptr = self->data, .len = ((uint64_t)self->length) };
    return __llpl_ret43;
}


// Module: /home/nix/Claude/LLPL/prelude.llpl (structs)

// Module: /home/nix/Claude/LLPL/prelude.llpl
#line 23 "/home/nix/Claude/LLPL/prelude.llpl"
extern int64_t ksnprintf(char* buf, uint64_t size, char* fmt, ...);

#line 32 "/home/nix/Claude/LLPL/prelude.llpl"
extern int64_t puts(char* s);

#line 41 "/home/nix/Claude/LLPL/prelude.llpl"
extern void llpl_panic(char* msg);

#line 47 "/home/nix/Claude/LLPL/prelude.llpl"
extern uint64_t llpl_strlen(char* s);

#line 48 "/home/nix/Claude/LLPL/prelude.llpl"
extern int64_t llpl_strcmp(char* a, char* b);

#line 49 "/home/nix/Claude/LLPL/prelude.llpl"
extern bool llpl_utf8_valid(char* s);

#line 50 "/home/nix/Claude/LLPL/prelude.llpl"
extern uint64_t llpl_utf8_len(char* s);

#line 51 "/home/nix/Claude/LLPL/prelude.llpl"
extern uint64_t llpl_utf8_byte_offset(char* s, uint64_t char_index);

#line 52 "/home/nix/Claude/LLPL/prelude.llpl"
extern uint64_t llpl_utf8_char_index(char* s, uint64_t byte_offset);

#line 53 "/home/nix/Claude/LLPL/prelude.llpl"
extern uint64_t llpl_utf8_codepoint_at(char* s, uint64_t char_index);

#line 54 "/home/nix/Claude/LLPL/prelude.llpl"
extern bool llpl_regex_match(char* pattern, char* text);

#line 55 "/home/nix/Claude/LLPL/prelude.llpl"
extern uint64_t llpl_regex_group_count(char* pattern);

#line 56 "/home/nix/Claude/LLPL/prelude.llpl"
extern bool llpl_regex_capture_bounds(char* pattern, char* text, uint64_t group, int64_t* start, int64_t* end);

#line 57 "/home/nix/Claude/LLPL/prelude.llpl"
extern char* llpl_regex_capture(char* pattern, char* text, uint64_t group);

#line 58 "/home/nix/Claude/LLPL/prelude.llpl"
extern char* llpl_reflect_type(char* name);

#line 59 "/home/nix/Claude/LLPL/prelude.llpl"
extern char* llpl_reflect_type_name(char* type);

#line 60 "/home/nix/Claude/LLPL/prelude.llpl"
extern char* llpl_reflect_type_kind(char* type);

#line 61 "/home/nix/Claude/LLPL/prelude.llpl"
extern uint64_t llpl_reflect_type_size(char* type);

#line 62 "/home/nix/Claude/LLPL/prelude.llpl"
extern uint64_t llpl_reflect_field_count(char* type);

#line 63 "/home/nix/Claude/LLPL/prelude.llpl"
extern char* llpl_reflect_field(char* type, uint64_t index);

#line 64 "/home/nix/Claude/LLPL/prelude.llpl"
extern char* llpl_reflect_field_name(char* field);

#line 65 "/home/nix/Claude/LLPL/prelude.llpl"
extern char* llpl_reflect_field_type_name(char* field);

#line 66 "/home/nix/Claude/LLPL/prelude.llpl"
extern uint64_t llpl_reflect_field_offset(char* field);

#line 67 "/home/nix/Claude/LLPL/prelude.llpl"
extern uint64_t llpl_reflect_field_size(char* field);

#line 68 "/home/nix/Claude/LLPL/prelude.llpl"
extern char* llpl_alloc(uint64_t size);

#line 69 "/home/nix/Claude/LLPL/prelude.llpl"
extern void llpl_free(char* ptr);

#line 70 "/home/nix/Claude/LLPL/prelude.llpl"
extern void llpl_memcpy(char* dest, char* src, uint64_t count);

#line 75 "/home/nix/Claude/LLPL/prelude.llpl"
extern void rc_retain(char* ptr);

#line 76 "/home/nix/Claude/LLPL/prelude.llpl"
extern void rc_weak_retain(char* ptr);

#line 77 "/home/nix/Claude/LLPL/prelude.llpl"
extern void rc_weak_release(char* ptr);

#line 78 "/home/nix/Claude/LLPL/prelude.llpl"
extern bool rc_is_alive(char* ptr);

#line 84 "/home/nix/Claude/LLPL/prelude.llpl"
extern char* llpl_resolve_symbol(uint64_t addr);

#line 85 "/home/nix/Claude/LLPL/prelude.llpl"
extern char* llpl_symbol_name(char* symbol);

#line 86 "/home/nix/Claude/LLPL/prelude.llpl"
extern char* llpl_symbol_file(char* symbol);

#line 87 "/home/nix/Claude/LLPL/prelude.llpl"
extern int64_t llpl_symbol_line(char* symbol);

#line 88 "/home/nix/Claude/LLPL/prelude.llpl"
extern void llpl_panic_backtrace();

#line 96 "/home/nix/Claude/LLPL/prelude.llpl"
extern void llpl_panic(char* msg);

#line 97 "/home/nix/Claude/LLPL/prelude.llpl"
extern void* __llpl_check_index(void* arr, int64_t idx, int64_t size, uint64_t elem_size);

ReflectField* ReflectField_new(char* raw) {
    ReflectField* self = (ReflectField*)rc_alloc(sizeof(ReflectField));
    if (!self) return NULL;
    rc_init(&self->ref_count);

    self->raw = raw;
    return self;
}

void ReflectField_destroy(void* ptr) {
    ReflectField* self = (ReflectField*)ptr;
}

bool ReflectField_exists(ReflectField* self) {
#line 114 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret44 = (((uint64_t)self->raw) != ((uint64_t)0));
    return __llpl_ret44;
}

char* ReflectField_name(ReflectField* self) {
#line 118 "/home/nix/Claude/LLPL/prelude.llpl"
    char* __llpl_ret45 = llpl_reflect_field_name(self->raw);
    return __llpl_ret45;
}

char* ReflectField_type_name(ReflectField* self) {
#line 122 "/home/nix/Claude/LLPL/prelude.llpl"
    char* __llpl_ret46 = llpl_reflect_field_type_name(self->raw);
    return __llpl_ret46;
}

int64_t ReflectField_offset(ReflectField* self) {
#line 126 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t __llpl_ret47 = ((int64_t)llpl_reflect_field_offset(self->raw));
    return __llpl_ret47;
}

int64_t ReflectField_size(ReflectField* self) {
#line 130 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t __llpl_ret48 = ((int64_t)llpl_reflect_field_size(self->raw));
    return __llpl_ret48;
}


ReflectType* ReflectType_new(char* raw) {
    ReflectType* self = (ReflectType*)rc_alloc(sizeof(ReflectType));
    if (!self) return NULL;
    rc_init(&self->ref_count);

    self->raw = raw;
    return self;
}

void ReflectType_destroy(void* ptr) {
    ReflectType* self = (ReflectType*)ptr;
}

bool ReflectType_exists(ReflectType* self) {
#line 144 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret49 = (((uint64_t)self->raw) != ((uint64_t)0));
    return __llpl_ret49;
}

char* ReflectType_name(ReflectType* self) {
#line 148 "/home/nix/Claude/LLPL/prelude.llpl"
    char* __llpl_ret50 = llpl_reflect_type_name(self->raw);
    return __llpl_ret50;
}

char* ReflectType_kind(ReflectType* self) {
#line 152 "/home/nix/Claude/LLPL/prelude.llpl"
    char* __llpl_ret51 = llpl_reflect_type_kind(self->raw);
    return __llpl_ret51;
}

int64_t ReflectType_size(ReflectType* self) {
#line 156 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t __llpl_ret52 = ((int64_t)llpl_reflect_type_size(self->raw));
    return __llpl_ret52;
}

int64_t ReflectType_field_count(ReflectType* self) {
#line 160 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t __llpl_ret53 = ((int64_t)llpl_reflect_field_count(self->raw));
    return __llpl_ret53;
}

ReflectField* ReflectType_field(ReflectType* self, int64_t index) {
    if ((index < 0)) {
#line 165 "/home/nix/Claude/LLPL/prelude.llpl"
        ReflectField* __llpl_ret54 = ReflectField_new(NULL);
        return __llpl_ret54;
    }
#line 167 "/home/nix/Claude/LLPL/prelude.llpl"
    ReflectField* __llpl_ret55 = ReflectField_new(llpl_reflect_field(self->raw, ((uint64_t)index)));
    return __llpl_ret55;
}



RegexMatch* RegexMatch_new(char* pattern, char* text, int64_t base_offset) {
    RegexMatch* self = (RegexMatch*)rc_alloc(sizeof(RegexMatch));
    if (!self) return NULL;
    rc_init(&self->ref_count);

#line 188 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t pattern_len = ((int64_t)llpl_strlen(pattern));
    self->pattern = llpl_alloc(((uint64_t)(pattern_len + 1)));
    llpl_memcpy(self->pattern, pattern, ((uint64_t)(pattern_len + 1)));
#line 192 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t text_len = ((int64_t)llpl_strlen(text));
    self->text = llpl_alloc(((uint64_t)(text_len + 1)));
    llpl_memcpy(self->text, text, ((uint64_t)(text_len + 1)));
    self->base_offset = base_offset;
    self->matched = llpl_regex_match(self->pattern, self->text);
    return self;
}

void RegexMatch_destroy(void* ptr) {
    RegexMatch* self = (RegexMatch*)ptr;
    llpl_free(self->pattern);
    llpl_free(self->text);
}

bool RegexMatch_is_match(RegexMatch* self) {
#line 206 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret56 = self->matched;
    return __llpl_ret56;
}

int64_t RegexMatch_group_count(RegexMatch* self) {
#line 210 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t __llpl_ret57 = ((int64_t)llpl_regex_group_count(self->pattern));
    return __llpl_ret57;
}

bool RegexMatch_has_group(RegexMatch* self, int64_t index) {
    if ((index < 0)) {
#line 215 "/home/nix/Claude/LLPL/prelude.llpl"
        bool __llpl_ret58 = 0;
        return __llpl_ret58;
    }
#line 217 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t start = 0;
#line 218 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t end = 0;
#line 219 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret59 = llpl_regex_capture_bounds(self->pattern, self->text, ((uint64_t)index), &start, &end);
    return __llpl_ret59;
}

int64_t RegexMatch_group_start(RegexMatch* self, int64_t index) {
    if ((index < 0)) {
#line 224 "/home/nix/Claude/LLPL/prelude.llpl"
        int64_t __llpl_ret60 = -1;
        return __llpl_ret60;
    }
#line 226 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t start = 0;
#line 227 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t end = 0;
    if (llpl_regex_capture_bounds(self->pattern, self->text, ((uint64_t)index), &start, &end)) {
#line 229 "/home/nix/Claude/LLPL/prelude.llpl"
        int64_t __llpl_ret61 = (start + self->base_offset);
        return __llpl_ret61;
    }
#line 231 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t __llpl_ret62 = -1;
    return __llpl_ret62;
}

int64_t RegexMatch_group_end(RegexMatch* self, int64_t index) {
    if ((index < 0)) {
#line 236 "/home/nix/Claude/LLPL/prelude.llpl"
        int64_t __llpl_ret63 = -1;
        return __llpl_ret63;
    }
#line 238 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t start = 0;
#line 239 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t end = 0;
    if (llpl_regex_capture_bounds(self->pattern, self->text, ((uint64_t)index), &start, &end)) {
#line 241 "/home/nix/Claude/LLPL/prelude.llpl"
        int64_t __llpl_ret64 = (end + self->base_offset);
        return __llpl_ret64;
    }
#line 243 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t __llpl_ret65 = -1;
    return __llpl_ret65;
}

String* RegexMatch_group(RegexMatch* self, int64_t index) {
    if ((index < 0)) {
#line 248 "/home/nix/Claude/LLPL/prelude.llpl"
        String* __llpl_ret66 = String_new("");
        return __llpl_ret66;
    }
#line 250 "/home/nix/Claude/LLPL/prelude.llpl"
    char* raw = llpl_regex_capture(self->pattern, self->text, ((uint64_t)index));
#line 251 "/home/nix/Claude/LLPL/prelude.llpl"
    String* out = String_new(raw);
    llpl_free(raw);
#line 253 "/home/nix/Claude/LLPL/prelude.llpl"
    String* __llpl_ret67 = out;
    return __llpl_ret67;
}

String* RegexMatch_expand(RegexMatch* self, char* template) {
#line 262 "/home/nix/Claude/LLPL/prelude.llpl"
    String* ts = String_new(template);
#line 263 "/home/nix/Claude/LLPL/prelude.llpl"
    String* result = String_new("");
#line 264 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t len = String_byte_len(ts);
#line 265 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t lit_start = 0;
#line 266 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t i = 0;
    while ((i < len)) {
        if (((String_byte_at(ts, i) == ((char)36)) && ((i + 1) < len))) {
            if ((i > lit_start)) {
                result = String_op_add(result, String_c_str(String_byte_substring(ts, lit_start, (i - lit_start))));
            }
#line 272 "/home/nix/Claude/LLPL/prelude.llpl"
            char next = String_byte_at(ts, (i + 1));
            if ((next == ((char)36))) {
                result = String_op_add(result, "$");
                i = (i + 2);
            } else {
                if (((next >= ((char)48)) && (next <= ((char)57)))) {
#line 277 "/home/nix/Claude/LLPL/prelude.llpl"
                    int64_t group_index = (((int64_t)next) - 48);
#line 278 "/home/nix/Claude/LLPL/prelude.llpl"
                    int64_t j = (i + 2);
                    while ((((j < len) && (String_byte_at(ts, j) >= ((char)48))) && (String_byte_at(ts, j) <= ((char)57)))) {
                        group_index = ((group_index * 10) + (((int64_t)String_byte_at(ts, j)) - 48));
                        j = (j + 1);
                    }
                    if (RegexMatch_has_group(self, group_index)) {
                        result = String_op_add(result, String_c_str(RegexMatch_group(self, group_index)));
                    }
                    i = j;
                } else {
                    result = String_op_add(result, "$");
                    i = (i + 1);
                }
            }
            lit_start = i;
        } else {
            i = (i + 1);
        }
    }
    if ((len > lit_start)) {
        result = String_op_add(result, String_c_str(String_byte_substring(ts, lit_start, (len - lit_start))));
    }
#line 299 "/home/nix/Claude/LLPL/prelude.llpl"
    String* __llpl_ret68 = result;
    return __llpl_ret68;
}


RegexMatchIterator* RegexMatchIterator_new(char* pattern, char* text) {
    RegexMatchIterator* self = (RegexMatchIterator*)rc_alloc(sizeof(RegexMatchIterator));
    if (!self) return NULL;
    rc_init(&self->ref_count);

#line 324 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t pattern_len = ((int64_t)llpl_strlen(pattern));
    self->pattern = llpl_alloc(((uint64_t)(pattern_len + 1)));
    llpl_memcpy(self->pattern, pattern, ((uint64_t)(pattern_len + 1)));
    self->text_len = ((int64_t)llpl_strlen(text));
    self->text = llpl_alloc(((uint64_t)(self->text_len + 1)));
    llpl_memcpy(self->text, text, ((uint64_t)(self->text_len + 1)));
    self->pos = 0;
    self->has_current = 0;
    self->done = 0;
    return self;
}

void RegexMatchIterator_destroy(void* ptr) {
    RegexMatchIterator* self = (RegexMatchIterator*)ptr;
    llpl_free(self->pattern);
    llpl_free(self->text);
    if (self->current) rc_release(self->current, RegexMatch_destroy);
}

bool RegexMatchIterator_advance(RegexMatchIterator* self) {
    if ((self->done || (self->pos > self->text_len))) {
        self->done = 1;
#line 345 "/home/nix/Claude/LLPL/prelude.llpl"
        bool __llpl_ret69 = 0;
        return __llpl_ret69;
    }
#line 347 "/home/nix/Claude/LLPL/prelude.llpl"
    RegexMatch* m = RegexMatch_new(self->pattern, (self->text + self->pos), self->pos);
    if (!RegexMatch_is_match(m)) {
        self->done = 1;
#line 350 "/home/nix/Claude/LLPL/prelude.llpl"
        bool __llpl_ret70 = 0;
        return __llpl_ret70;
    }
    self->current = m;
#line 353 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t end_in_suffix = (RegexMatch_group_end(m, 0) - self->pos);
#line 354 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t start_in_suffix = (RegexMatch_group_start(m, 0) - self->pos);
    if ((end_in_suffix == start_in_suffix)) {
        self->pos = ((self->pos + end_in_suffix) + 1);
    } else {
        self->pos = (self->pos + end_in_suffix);
    }
#line 360 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret71 = 1;
    return __llpl_ret71;
}

bool RegexMatchIterator_iter_has_next(RegexMatchIterator* self) {
    if (self->has_current) {
#line 365 "/home/nix/Claude/LLPL/prelude.llpl"
        bool __llpl_ret72 = 1;
        return __llpl_ret72;
    }
    self->has_current = RegexMatchIterator_advance(self);
#line 368 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret73 = self->has_current;
    return __llpl_ret73;
}

RegexMatch* RegexMatchIterator_iter_next(RegexMatchIterator* self) {
    if (!self->has_current) {
        RegexMatchIterator_advance(self);
    }
    self->has_current = 0;
#line 376 "/home/nix/Claude/LLPL/prelude.llpl"
    RegexMatch* __llpl_ret74 = self->current;
    return __llpl_ret74;
}


Regex* Regex_new(char* pattern) {
    Regex* self = (Regex*)rc_alloc(sizeof(Regex));
    if (!self) return NULL;
    rc_init(&self->ref_count);

#line 384 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t len = ((int64_t)llpl_strlen(pattern));
    self->pattern = llpl_alloc(((uint64_t)(len + 1)));
    llpl_memcpy(self->pattern, pattern, ((uint64_t)(len + 1)));
    return self;
}

void Regex_destroy(void* ptr) {
    Regex* self = (Regex*)ptr;
    llpl_free(self->pattern);
}

bool Regex_match(Regex* self, char* text) {
#line 394 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret75 = llpl_regex_match(self->pattern, text);
    return __llpl_ret75;
}

RegexMatch* Regex_captures(Regex* self, char* text) {
#line 398 "/home/nix/Claude/LLPL/prelude.llpl"
    RegexMatch* __llpl_ret76 = RegexMatch_new(self->pattern, text, 0);
    return __llpl_ret76;
}

RegexMatchIterator* Regex_find_all(Regex* self, char* text) {
#line 404 "/home/nix/Claude/LLPL/prelude.llpl"
    RegexMatchIterator* __llpl_ret77 = RegexMatchIterator_new(self->pattern, text);
    return __llpl_ret77;
}

String* Regex_replace(Regex* self, char* text, char* replacement) {
#line 411 "/home/nix/Claude/LLPL/prelude.llpl"
    RegexMatch* m = Regex_captures(self, text);
    if (!RegexMatch_is_match(m)) {
#line 413 "/home/nix/Claude/LLPL/prelude.llpl"
        String* __llpl_ret78 = String_new(text);
        return __llpl_ret78;
    }
#line 415 "/home/nix/Claude/LLPL/prelude.llpl"
    String* ts = String_new(text);
#line 416 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t start = RegexMatch_group_start(m, 0);
#line 417 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t end = RegexMatch_group_end(m, 0);
#line 418 "/home/nix/Claude/LLPL/prelude.llpl"
    String* result = String_byte_substring(ts, 0, start);
    result = String_op_add(result, String_c_str(RegexMatch_expand(m, replacement)));
    result = String_op_add(result, String_c_str(String_byte_substring(ts, end, (String_byte_len(ts) - end))));
#line 421 "/home/nix/Claude/LLPL/prelude.llpl"
    String* __llpl_ret79 = result;
    return __llpl_ret79;
}

String* Regex_replace_all(Regex* self, char* text, char* replacement) {
#line 426 "/home/nix/Claude/LLPL/prelude.llpl"
    String* ts = String_new(text);
#line 427 "/home/nix/Claude/LLPL/prelude.llpl"
    String* result = String_new("");
#line 428 "/home/nix/Claude/LLPL/prelude.llpl"
    RegexMatchIterator* it = Regex_find_all(self, text);
#line 429 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t last_end = 0;
    while (RegexMatchIterator_iter_has_next(it)) {
#line 431 "/home/nix/Claude/LLPL/prelude.llpl"
        RegexMatch* m = RegexMatchIterator_iter_next(it);
#line 432 "/home/nix/Claude/LLPL/prelude.llpl"
        int64_t start = RegexMatch_group_start(m, 0);
#line 433 "/home/nix/Claude/LLPL/prelude.llpl"
        int64_t end = RegexMatch_group_end(m, 0);
        if ((start > last_end)) {
            result = String_op_add(result, String_c_str(String_byte_substring(ts, last_end, (start - last_end))));
        }
        result = String_op_add(result, String_c_str(RegexMatch_expand(m, replacement)));
        last_end = end;
    }
    if ((last_end < String_byte_len(ts))) {
        result = String_op_add(result, String_c_str(String_byte_substring(ts, last_end, (String_byte_len(ts) - last_end))));
    }
#line 443 "/home/nix/Claude/LLPL/prelude.llpl"
    String* __llpl_ret80 = result;
    return __llpl_ret80;
}

char* Regex_source(Regex* self) {
#line 447 "/home/nix/Claude/LLPL/prelude.llpl"
    char* __llpl_ret81 = self->pattern;
    return __llpl_ret81;
}


String* String_new(char* s) {
    String* self = (String*)rc_alloc(sizeof(String));
    if (!self) return NULL;
    rc_init(&self->ref_count);

    self->length = ((int64_t)llpl_strlen(s));
    self->buf = llpl_alloc(((uint64_t)(self->length + 1)));
    llpl_memcpy(self->buf, s, ((uint64_t)(self->length + 1)));
    self->iter_pos = 0;
    return self;
}

void String_destroy(void* ptr) {
    String* self = (String*)ptr;
    llpl_free(self->buf);
}

int64_t String_byte_len(String* self) {
#line 488 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t __llpl_ret82 = self->length;
    return __llpl_ret82;
}

int64_t String_len(String* self) {
#line 492 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t __llpl_ret83 = ((int64_t)llpl_utf8_len(self->buf));
    return __llpl_ret83;
}

bool String_is_utf8(String* self) {
#line 496 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret84 = llpl_utf8_valid(self->buf);
    return __llpl_ret84;
}

int64_t String_byte_index(String* self, int64_t char_index) {
    if ((char_index < 0)) {
#line 501 "/home/nix/Claude/LLPL/prelude.llpl"
        int64_t __llpl_ret85 = 0;
        return __llpl_ret85;
    }
#line 503 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t __llpl_ret86 = ((int64_t)llpl_utf8_byte_offset(self->buf, ((uint64_t)char_index)));
    return __llpl_ret86;
}

int64_t String_char_index(String* self, int64_t byte_offset) {
    if ((byte_offset < 0)) {
#line 508 "/home/nix/Claude/LLPL/prelude.llpl"
        int64_t __llpl_ret87 = 0;
        return __llpl_ret87;
    }
#line 510 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t __llpl_ret88 = ((int64_t)llpl_utf8_char_index(self->buf, ((uint64_t)byte_offset)));
    return __llpl_ret88;
}

uint64_t String_codepoint_at(String* self, int64_t char_index) {
    if ((char_index < 0)) {
#line 515 "/home/nix/Claude/LLPL/prelude.llpl"
        uint64_t __llpl_ret89 = ((uint64_t)0);
        return __llpl_ret89;
    }
#line 517 "/home/nix/Claude/LLPL/prelude.llpl"
    uint64_t __llpl_ret90 = llpl_utf8_codepoint_at(self->buf, ((uint64_t)char_index));
    return __llpl_ret90;
}

char* String_c_str(String* self) {
#line 524 "/home/nix/Claude/LLPL/prelude.llpl"
    char* __llpl_ret91 = self->buf;
    return __llpl_ret91;
}

char String_byte_at(String* self, int64_t index) {
#line 528 "/home/nix/Claude/LLPL/prelude.llpl"
    char __llpl_ret92 = self->buf[index];
    return __llpl_ret92;
}

uint64_t String_op_index(String* self, int64_t index) {
#line 532 "/home/nix/Claude/LLPL/prelude.llpl"
    uint64_t __llpl_ret93 = String_codepoint_at(self, index);
    return __llpl_ret93;
}

void String_iter_reset(String* self) {
    self->iter_pos = 0;
}

bool String_iter_has_next(String* self) {
#line 544 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret94 = (self->iter_pos < String_len(self));
    return __llpl_ret94;
}

uint64_t String_iter_next(String* self) {
#line 548 "/home/nix/Claude/LLPL/prelude.llpl"
    uint64_t c = String_codepoint_at(self, self->iter_pos);
    self->iter_pos = (self->iter_pos + 1);
#line 550 "/home/nix/Claude/LLPL/prelude.llpl"
    uint64_t __llpl_ret95 = c;
    return __llpl_ret95;
}

void String_byte_set(String* self, int64_t index, char value) {
    self->buf[index] = value;
}

bool String_op_eq_char_ptr(String* self, char* other) {
#line 558 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret96 = (llpl_strcmp(self->buf, other) == 0);
    return __llpl_ret96;
}

bool String_op_ne_char_ptr(String* self, char* other) {
#line 562 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret97 = !String_op_eq_char_ptr(self, other);
    return __llpl_ret97;
}

bool String_op_lt_char_ptr(String* self, char* other) {
#line 566 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret98 = (llpl_strcmp(self->buf, other) < 0);
    return __llpl_ret98;
}

bool String_op_gt_char_ptr(String* self, char* other) {
#line 570 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret99 = (llpl_strcmp(self->buf, other) > 0);
    return __llpl_ret99;
}

bool String_op_eq_String(String* self, String* other) {
#line 581 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret100 = String_op_eq_char_ptr(self, String_c_str(other));
    return __llpl_ret100;
}

bool String_op_ne_String(String* self, String* other) {
#line 585 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret101 = String_op_ne_char_ptr(self, String_c_str(other));
    return __llpl_ret101;
}

bool String_op_lt_String(String* self, String* other) {
#line 589 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret102 = String_op_lt_char_ptr(self, String_c_str(other));
    return __llpl_ret102;
}

bool String_op_gt_String(String* self, String* other) {
#line 593 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret103 = String_op_gt_char_ptr(self, String_c_str(other));
    return __llpl_ret103;
}

String* String_op_add(String* self, char* other) {
#line 603 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t other_len = ((int64_t)llpl_strlen(other));
#line 604 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t total = (self->length + other_len);
#line 605 "/home/nix/Claude/LLPL/prelude.llpl"
    char* joined = llpl_alloc(((uint64_t)(total + 1)));
    llpl_memcpy(joined, self->buf, ((uint64_t)self->length));
    llpl_memcpy((joined + self->length), other, ((uint64_t)(other_len + 1)));
#line 608 "/home/nix/Claude/LLPL/prelude.llpl"
    String* __llpl_ret104 = String_new(joined);
    return __llpl_ret104;
}

String* String_byte_substring(String* self, int64_t start, int64_t count) {
    if ((start < 0)) {
        start = 0;
    }
    if ((start > self->length)) {
        start = self->length;
    }
#line 620 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t max_count = (self->length - start);
    if ((count > max_count)) {
        count = max_count;
    }
    if ((count < 0)) {
        count = 0;
    }
#line 628 "/home/nix/Claude/LLPL/prelude.llpl"
    char* piece = llpl_alloc(((uint64_t)(count + 1)));
    llpl_memcpy(piece, (self->buf + start), ((uint64_t)count));
    piece[count] = ((char)0);
#line 631 "/home/nix/Claude/LLPL/prelude.llpl"
    String* __llpl_ret105 = String_new(piece);
    return __llpl_ret105;
}

String* String_substring(String* self, int64_t start, int64_t count) {
    if ((start < 0)) {
        start = 0;
    }
#line 638 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t total_chars = String_len(self);
    if ((start > total_chars)) {
        start = total_chars;
    }
#line 642 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t max_count = (total_chars - start);
    if ((count > max_count)) {
        count = max_count;
    }
    if ((count < 0)) {
        count = 0;
    }
#line 650 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t byte_start = String_byte_index(self, start);
#line 651 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t byte_end = String_byte_index(self, (start + count));
#line 652 "/home/nix/Claude/LLPL/prelude.llpl"
    String* __llpl_ret106 = String_byte_substring(self, byte_start, (byte_end - byte_start));
    return __llpl_ret106;
}

String* String_utf8_substring(String* self, int64_t start, int64_t count) {
#line 656 "/home/nix/Claude/LLPL/prelude.llpl"
    String* __llpl_ret107 = String_substring(self, start, count);
    return __llpl_ret107;
}

int64_t String_byte_find(String* self, char* needle) {
#line 661 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t needle_len = ((int64_t)llpl_strlen(needle));
    if ((needle_len == 0)) {
#line 663 "/home/nix/Claude/LLPL/prelude.llpl"
        int64_t __llpl_ret108 = 0;
        return __llpl_ret108;
    }
#line 665 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t i = 0;
    while ((i <= (self->length - needle_len))) {
#line 667 "/home/nix/Claude/LLPL/prelude.llpl"
        int64_t j = 0;
#line 668 "/home/nix/Claude/LLPL/prelude.llpl"
        bool matched = 1;
        while (((j < needle_len) && matched)) {
            if ((self->buf[(i + j)] != needle[j])) {
                matched = 0;
            }
            j = (j + 1);
        }
        if (matched) {
#line 676 "/home/nix/Claude/LLPL/prelude.llpl"
            int64_t __llpl_ret109 = i;
            return __llpl_ret109;
        }
        i = (i + 1);
    }
#line 680 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t __llpl_ret110 = -1;
    return __llpl_ret110;
}

int64_t String_find(String* self, char* needle) {
#line 686 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t byte_pos = String_byte_find(self, needle);
    if ((byte_pos < 0)) {
#line 688 "/home/nix/Claude/LLPL/prelude.llpl"
        int64_t __llpl_ret111 = -1;
        return __llpl_ret111;
    }
#line 690 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t __llpl_ret112 = String_char_index(self, byte_pos);
    return __llpl_ret112;
}

bool String_contains(String* self, char* needle) {
#line 694 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret113 = (String_find(self, needle) >= 0);
    return __llpl_ret113;
}

bool String_starts_with(String* self, char* prefix) {
#line 698 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t prefix_len = ((int64_t)llpl_strlen(prefix));
    if ((prefix_len > self->length)) {
#line 700 "/home/nix/Claude/LLPL/prelude.llpl"
        bool __llpl_ret114 = 0;
        return __llpl_ret114;
    }
#line 702 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t i = 0;
    while ((i < prefix_len)) {
        if ((self->buf[i] != prefix[i])) {
#line 705 "/home/nix/Claude/LLPL/prelude.llpl"
            bool __llpl_ret115 = 0;
            return __llpl_ret115;
        }
        i = (i + 1);
    }
#line 709 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret116 = 1;
    return __llpl_ret116;
}

bool String_ends_with(String* self, char* suffix) {
#line 713 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t suffix_len = ((int64_t)llpl_strlen(suffix));
    if ((suffix_len > self->length)) {
#line 715 "/home/nix/Claude/LLPL/prelude.llpl"
        bool __llpl_ret117 = 0;
        return __llpl_ret117;
    }
#line 717 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t offset = (self->length - suffix_len);
#line 718 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t i = 0;
    while ((i < suffix_len)) {
        if ((self->buf[(offset + i)] != suffix[i])) {
#line 721 "/home/nix/Claude/LLPL/prelude.llpl"
            bool __llpl_ret118 = 0;
            return __llpl_ret118;
        }
        i = (i + 1);
    }
#line 725 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret119 = 1;
    return __llpl_ret119;
}

String* String_to_upper(String* self) {
#line 729 "/home/nix/Claude/LLPL/prelude.llpl"
    char* out = llpl_alloc(((uint64_t)(self->length + 1)));
#line 730 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t i = 0;
    while ((i < self->length)) {
#line 732 "/home/nix/Claude/LLPL/prelude.llpl"
        char c = self->buf[i];
        if (((c >= ((char)97)) && (c <= ((char)122)))) {
            out[i] = ((char)(((int64_t)c) - 32));
        } else {
            out[i] = c;
        }
        i = (i + 1);
    }
    out[self->length] = ((char)0);
#line 741 "/home/nix/Claude/LLPL/prelude.llpl"
    String* __llpl_ret120 = String_new(out);
    return __llpl_ret120;
}

String* String_to_lower(String* self) {
#line 745 "/home/nix/Claude/LLPL/prelude.llpl"
    char* out = llpl_alloc(((uint64_t)(self->length + 1)));
#line 746 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t i = 0;
    while ((i < self->length)) {
#line 748 "/home/nix/Claude/LLPL/prelude.llpl"
        char c = self->buf[i];
        if (((c >= ((char)65)) && (c <= ((char)90)))) {
            out[i] = ((char)(((int64_t)c) + 32));
        } else {
            out[i] = c;
        }
        i = (i + 1);
    }
    out[self->length] = ((char)0);
#line 757 "/home/nix/Claude/LLPL/prelude.llpl"
    String* __llpl_ret121 = String_new(out);
    return __llpl_ret121;
}

String* String_trim(String* self) {
#line 762 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t start = 0;
    while (((start < self->length) && ((((self->buf[start] == ((char)32)) || (self->buf[start] == ((char)9))) || (self->buf[start] == ((char)10))) || (self->buf[start] == ((char)13))))) {
        start = (start + 1);
    }
#line 767 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t end = self->length;
    while (((end > start) && ((((self->buf[(end - 1)] == ((char)32)) || (self->buf[(end - 1)] == ((char)9))) || (self->buf[(end - 1)] == ((char)10))) || (self->buf[(end - 1)] == ((char)13))))) {
        end = (end - 1);
    }
#line 772 "/home/nix/Claude/LLPL/prelude.llpl"
    String* __llpl_ret122 = String_byte_substring(self, start, (end - start));
    return __llpl_ret122;
}


OwnedBuffer* OwnedBuffer_new(uint64_t size) {
    OwnedBuffer* self = (OwnedBuffer*)rc_alloc(sizeof(OwnedBuffer));
    if (!self) return NULL;
    rc_init(&self->ref_count);

    self->ptr = llpl_alloc(size);
    self->length = size;
    return self;
}

void OwnedBuffer_destroy(void* ptr) {
    OwnedBuffer* self = (OwnedBuffer*)ptr;
    OwnedBuffer_free(self);
}

void OwnedBuffer_free(OwnedBuffer* self) {
    if ((self->ptr != NULL)) {
        llpl_free(self->ptr);
        self->ptr = NULL;
        self->length = ((uint64_t)0);
    }
}

char* OwnedBuffer_data(OwnedBuffer* self) {
#line 840 "/home/nix/Claude/LLPL/prelude.llpl"
    char* __llpl_ret123 = self->ptr;
    return __llpl_ret123;
}

uint64_t OwnedBuffer_len(OwnedBuffer* self) {
#line 844 "/home/nix/Claude/LLPL/prelude.llpl"
    uint64_t __llpl_ret124 = self->length;
    return __llpl_ret124;
}

bool OwnedBuffer_is_null(OwnedBuffer* self) {
#line 848 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret125 = (self->ptr == NULL);
    return __llpl_ret125;
}

char OwnedBuffer_byte_at(OwnedBuffer* self, uint64_t index) {
    if ((index >= self->length)) {
        llpl_panic("OwnedBuffer.byte_at: index out of bounds");
    }
#line 855 "/home/nix/Claude/LLPL/prelude.llpl"
    char __llpl_ret126 = self->ptr[((int64_t)index)];
    return __llpl_ret126;
}

void OwnedBuffer_set(OwnedBuffer* self, uint64_t index, char value) {
    if ((index >= self->length)) {
        llpl_panic("OwnedBuffer.set: index out of bounds");
    }
    self->ptr[((int64_t)index)] = value;
}

Slice_char OwnedBuffer_as_slice(OwnedBuffer* self) {
#line 866 "/home/nix/Claude/LLPL/prelude.llpl"
    Slice_char s;
    s.ptr = self->ptr;
    s.len = self->length;
#line 869 "/home/nix/Claude/LLPL/prelude.llpl"
    Slice_char __llpl_ret127 = s;
    return __llpl_ret127;
}

char* OwnedBuffer_take(OwnedBuffer* self) {
#line 873 "/home/nix/Claude/LLPL/prelude.llpl"
    char* out = self->ptr;
    self->ptr = NULL;
    self->length = ((uint64_t)0);
#line 876 "/home/nix/Claude/LLPL/prelude.llpl"
    char* __llpl_ret128 = out;
    return __llpl_ret128;
}


ParseNode* ParseNode_new() {
    ParseNode* self = (ParseNode*)rc_alloc(sizeof(ParseNode));
    if (!self) return NULL;
    rc_init(&self->ref_count);

    self->rule_name = String_new("");
    self->text_val = String_new("");
    self->children = Vector_ParseNode_new();
    self->is_terminal = 0;
    return self;
}

void ParseNode_destroy(void* ptr) {
    ParseNode* self = (ParseNode*)ptr;
    if (self->rule_name) rc_release(self->rule_name, String_destroy);
    if (self->text_val) rc_release(self->text_val, String_destroy);
    if (self->children) rc_release(self->children, Vector_ParseNode_destroy);
}

String* ParseNode_name(ParseNode* self) {
#line 1345 "/home/nix/Claude/LLPL/prelude.llpl"
    String* __llpl_ret129 = self->rule_name;
    return __llpl_ret129;
}

String* ParseNode_text(ParseNode* self) {
#line 1349 "/home/nix/Claude/LLPL/prelude.llpl"
    String* __llpl_ret130 = self->text_val;
    return __llpl_ret130;
}

ParseNode* ParseNode_child(ParseNode* self, int64_t index) {
#line 1353 "/home/nix/Claude/LLPL/prelude.llpl"
    ParseNode* __llpl_ret131 = Vector_ParseNode_get(self->children, index);
    return __llpl_ret131;
}

int64_t ParseNode_child_count(ParseNode* self) {
#line 1357 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t __llpl_ret132 = Vector_ParseNode_len(self->children);
    return __llpl_ret132;
}


// Module: /home/nix/Claude/LLPL/test/ui_dsl_demo.llpl
#line 3 "/home/nix/Claude/LLPL/test/ui_dsl_demo.llpl"
Window* DemoWindow_build() {
#line 3 "/home/nix/Claude/LLPL/test/ui_dsl_demo.llpl"
    Window* __ui0 = Window_new();
    __ui0->title = "Counter";
    __ui0->width = 320;
    __ui0->height = 180;
#line 8 "/home/nix/Claude/LLPL/test/ui_dsl_demo.llpl"
    Column* __ui1 = Column_new();
    __ui1->spacing = 8;
    Window_add_child(__ui0, __ui1);
#line 11 "/home/nix/Claude/LLPL/test/ui_dsl_demo.llpl"
    Text* __ui2 = Text_new();
    __ui2->text = "Count: 0";
    Column_add_child(__ui1, __ui2);
#line 15 "/home/nix/Claude/LLPL/test/ui_dsl_demo.llpl"
    Button* __ui3 = Button_new();
    __ui3->text = "Increment";
    Column_add_child(__ui1, __ui3);
#line 3 "/home/nix/Claude/LLPL/test/ui_dsl_demo.llpl"
    Window* __llpl_ret133 = __ui0;
    return __llpl_ret133;
}

#line 21 "/home/nix/Claude/LLPL/test/ui_dsl_demo.llpl"
int64_t main() {
#line 22 "/home/nix/Claude/LLPL/test/ui_dsl_demo.llpl"
    Window* window = DemoWindow_build();
#line 23 "/home/nix/Claude/LLPL/test/ui_dsl_demo.llpl"
    App* app = App_new("Demo", 640, 480, window);
    App_run(app);
#line 25 "/home/nix/Claude/LLPL/test/ui_dsl_demo.llpl"
    int64_t __llpl_ret134 = 0;
    return __llpl_ret134;
}

// Function bodies deferred until after plain class/struct definitions exist
uint64_t i64_hash(int64_t self) {
#line 1459 "/home/nix/Claude/LLPL/prelude.llpl"
    uint64_t __llpl_ret1 = ((uint64_t)self);
    return __llpl_ret1;
}
bool i64_equals(int64_t self, int64_t other) {
#line 1462 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret2 = (self == other);
    return __llpl_ret2;
}
uint64_t u64_hash(uint64_t self) {
#line 1468 "/home/nix/Claude/LLPL/prelude.llpl"
    uint64_t __llpl_ret3 = self;
    return __llpl_ret3;
}
bool u64_equals(uint64_t self, uint64_t other) {
#line 1471 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret4 = (self == other);
    return __llpl_ret4;
}
uint64_t u8_hash(uint8_t self) {
#line 1477 "/home/nix/Claude/LLPL/prelude.llpl"
    uint64_t __llpl_ret5 = ((uint64_t)self);
    return __llpl_ret5;
}
bool u8_equals(uint8_t self, uint8_t other) {
#line 1480 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret6 = (self == other);
    return __llpl_ret6;
}
uint64_t char_ptr_hash(char* self) {
#line 1490 "/home/nix/Claude/LLPL/prelude.llpl"
    uint64_t len = llpl_strlen(self);
#line 1491 "/home/nix/Claude/LLPL/prelude.llpl"
    uint64_t h = ((uint64_t)2166136261);
#line 1492 "/home/nix/Claude/LLPL/prelude.llpl"
    uint64_t i = ((uint64_t)0);
    while ((i < len)) {
        h = (h ^ ((uint64_t)self[i]));
        h = (h * ((uint64_t)16777619));
        i = (i + ((uint64_t)1));
    }
#line 1498 "/home/nix/Claude/LLPL/prelude.llpl"
    uint64_t __llpl_ret7 = h;
    return __llpl_ret7;
}
bool char_ptr_equals(char* self, char* other) {
#line 1501 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret8 = (llpl_strcmp(self, other) == 0);
    return __llpl_ret8;
}
uint64_t String_hash(String* self) {
#line 1509 "/home/nix/Claude/LLPL/prelude.llpl"
    uint64_t h = ((uint64_t)2166136261);
#line 1510 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t i = 0;
    while ((i < self->length)) {
        h = (h ^ ((uint64_t)self->buf[i]));
        h = (h * ((uint64_t)16777619));
        i = (i + 1);
    }
#line 1516 "/home/nix/Claude/LLPL/prelude.llpl"
    uint64_t __llpl_ret9 = h;
    return __llpl_ret9;
}
bool String_equals(String* self, String* other) {
    if ((self->length != other->length)) {
#line 1520 "/home/nix/Claude/LLPL/prelude.llpl"
        bool __llpl_ret10 = 0;
        return __llpl_ret10;
    }
#line 1522 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret11 = (llpl_strcmp(self->buf, other->buf) == 0);
    return __llpl_ret11;
}
int64_t i64_compare(int64_t self, int64_t other) {
    if ((self < other)) {
#line 1534 "/home/nix/Claude/LLPL/prelude.llpl"
        int64_t __llpl_ret12 = -1;
        return __llpl_ret12;
    }
    if ((self > other)) {
#line 1535 "/home/nix/Claude/LLPL/prelude.llpl"
        int64_t __llpl_ret13 = 1;
        return __llpl_ret13;
    }
#line 1536 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t __llpl_ret14 = 0;
    return __llpl_ret14;
}
int64_t u64_compare(uint64_t self, uint64_t other) {
    if ((self < other)) {
#line 1542 "/home/nix/Claude/LLPL/prelude.llpl"
        int64_t __llpl_ret15 = -1;
        return __llpl_ret15;
    }
    if ((self > other)) {
#line 1543 "/home/nix/Claude/LLPL/prelude.llpl"
        int64_t __llpl_ret16 = 1;
        return __llpl_ret16;
    }
#line 1544 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t __llpl_ret17 = 0;
    return __llpl_ret17;
}
int64_t u8_compare(uint8_t self, uint8_t other) {
    if ((self < other)) {
#line 1550 "/home/nix/Claude/LLPL/prelude.llpl"
        int64_t __llpl_ret18 = -1;
        return __llpl_ret18;
    }
    if ((self > other)) {
#line 1551 "/home/nix/Claude/LLPL/prelude.llpl"
        int64_t __llpl_ret19 = 1;
        return __llpl_ret19;
    }
#line 1552 "/home/nix/Claude/LLPL/prelude.llpl"
    int64_t __llpl_ret20 = 0;
    return __llpl_ret20;
}
bool char_ptr_op_eq(char* self, char* other) {
#line 1570 "/home/nix/Claude/LLPL/prelude.llpl"
    bool self_null = (((uint64_t)self) == ((uint64_t)0));
#line 1571 "/home/nix/Claude/LLPL/prelude.llpl"
    bool other_null = (((uint64_t)other) == ((uint64_t)0));
    if ((self_null || other_null)) {
#line 1573 "/home/nix/Claude/LLPL/prelude.llpl"
        bool __llpl_ret21 = (self_null && other_null);
        return __llpl_ret21;
    }
#line 1575 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret22 = (llpl_strcmp(self, other) == 0);
    return __llpl_ret22;
}
bool char_ptr_op_ne(char* self, char* other) {
#line 1579 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret23 = !(self == other);
    return __llpl_ret23;
}
bool char_ptr_op_lt(char* self, char* other) {
#line 1583 "/home/nix/Claude/LLPL/prelude.llpl"
    bool self_null = (((uint64_t)self) == ((uint64_t)0));
#line 1584 "/home/nix/Claude/LLPL/prelude.llpl"
    bool other_null = (((uint64_t)other) == ((uint64_t)0));
    if ((self_null || other_null)) {
#line 1586 "/home/nix/Claude/LLPL/prelude.llpl"
        bool __llpl_ret24 = (self_null && !other_null);
        return __llpl_ret24;
    }
#line 1588 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret25 = (llpl_strcmp(self, other) < 0);
    return __llpl_ret25;
}
bool char_ptr_op_gt(char* self, char* other) {
#line 1592 "/home/nix/Claude/LLPL/prelude.llpl"
    bool self_null = (((uint64_t)self) == ((uint64_t)0));
#line 1593 "/home/nix/Claude/LLPL/prelude.llpl"
    bool other_null = (((uint64_t)other) == ((uint64_t)0));
    if ((self_null || other_null)) {
#line 1595 "/home/nix/Claude/LLPL/prelude.llpl"
        bool __llpl_ret26 = (!self_null && other_null);
        return __llpl_ret26;
    }
#line 1597 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret27 = (llpl_strcmp(self, other) > 0);
    return __llpl_ret27;
}
bool char_ptr_op_le(char* self, char* other) {
#line 1601 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret28 = !(self > other);
    return __llpl_ret28;
}
bool char_ptr_op_ge(char* self, char* other) {
#line 1605 "/home/nix/Claude/LLPL/prelude.llpl"
    bool __llpl_ret29 = !(self < other);
    return __llpl_ret29;
}

// Symbol table for symbolized panic backtraces
LLPL_Symbol llpl_symbol_table[] = {
    { "u8_equals", (void*)u8_equals, "?", 1479 },
    { "char_ptr_equals", (void*)char_ptr_equals, "?", 1500 },
    { "DemoWindow_build", (void*)DemoWindow_build, "ui_dsl_demo.llpl", 3 },
    { "char_ptr_op_ne", (void*)char_ptr_op_ne, "?", 1578 },
    { "char_ptr_op_lt", (void*)char_ptr_op_lt, "?", 1582 },
    { "char_ptr_hash", (void*)char_ptr_hash, "?", 1489 },
    { "i64_hash", (void*)i64_hash, "?", 1458 },
    { "i64_equals", (void*)i64_equals, "?", 1461 },
    { "char_ptr_op_ge", (void*)char_ptr_op_ge, "?", 1604 },
    { "char_ptr_op_gt", (void*)char_ptr_op_gt, "?", 1591 },
    { "u8_hash", (void*)u8_hash, "?", 1476 },
    { "char_ptr_op_eq", (void*)char_ptr_op_eq, "?", 1569 },
    { "char_ptr_op_le", (void*)char_ptr_op_le, "?", 1600 },
    { "String_hash", (void*)String_hash, "?", 1508 },
    { "u64_equals", (void*)u64_equals, "?", 1470 },
    { "u64_compare", (void*)u64_compare, "?", 1541 },
    { "String_equals", (void*)String_equals, "?", 1518 },
    { "main", (void*)main, "ui_dsl_demo.llpl", 21 },
    { "i64_compare", (void*)i64_compare, "?", 1533 },
    { "u8_compare", (void*)u8_compare, "?", 1549 },
    { "u64_hash", (void*)u64_hash, "?", 1467 },
    { "ReflectType_new", (void*)ReflectType_new, "prelude.llpl", 137 },
    { "ReflectType_exists", (void*)ReflectType_exists, "prelude.llpl", 143 },
    { "ReflectType_name", (void*)ReflectType_name, "prelude.llpl", 147 },
    { "ReflectType_kind", (void*)ReflectType_kind, "prelude.llpl", 151 },
    { "ReflectType_size", (void*)ReflectType_size, "prelude.llpl", 155 },
    { "ReflectType_field_count", (void*)ReflectType_field_count, "prelude.llpl", 159 },
    { "ReflectType_field", (void*)ReflectType_field, "prelude.llpl", 163 },
    { "RegexMatchIterator_new", (void*)RegexMatchIterator_new, "prelude.llpl", 323 },
    { "RegexMatchIterator_advance", (void*)RegexMatchIterator_advance, "prelude.llpl", 342 },
    { "RegexMatchIterator_iter_has_next", (void*)RegexMatchIterator_iter_has_next, "prelude.llpl", 363 },
    { "RegexMatchIterator_iter_next", (void*)RegexMatchIterator_iter_next, "prelude.llpl", 371 },
    { "Vector_ParseNode_new", (void*)Vector_ParseNode_new, "?", 1011 },
    { "Vector_ParseNode_new_i64_ParseNode", (void*)Vector_ParseNode_new_i64_ParseNode, "?", 1023 },
    { "Vector_ParseNode_push", (void*)Vector_ParseNode_push, "?", 1047 },
    { "Vector_ParseNode_grow", (void*)Vector_ParseNode_grow, "?", 1055 },
    { "Vector_ParseNode_get", (void*)Vector_ParseNode_get, "?", 1064 },
    { "Vector_ParseNode_set", (void*)Vector_ParseNode_set, "?", 1071 },
    { "Vector_ParseNode_pop", (void*)Vector_ParseNode_pop, "?", 1078 },
    { "Vector_ParseNode_len", (void*)Vector_ParseNode_len, "?", 1083 },
    { "Vector_ParseNode_is_empty", (void*)Vector_ParseNode_is_empty, "?", 1087 },
    { "Vector_ParseNode_push_back", (void*)Vector_ParseNode_push_back, "?", 1102 },
    { "Vector_ParseNode_pop_back", (void*)Vector_ParseNode_pop_back, "?", 1106 },
    { "Vector_ParseNode_size", (void*)Vector_ParseNode_size, "?", 1110 },
    { "Vector_ParseNode_empty", (void*)Vector_ParseNode_empty, "?", 1114 },
    { "Vector_ParseNode_clear", (void*)Vector_ParseNode_clear, "?", 1120 },
    { "Vector_ParseNode_reserve", (void*)Vector_ParseNode_reserve, "?", 1129 },
    { "Vector_ParseNode_resize", (void*)Vector_ParseNode_resize, "?", 1147 },
    { "Vector_ParseNode_front", (void*)Vector_ParseNode_front, "?", 1159 },
    { "Vector_ParseNode_back", (void*)Vector_ParseNode_back, "?", 1163 },
    { "Vector_ParseNode_at", (void*)Vector_ParseNode_at, "?", 1167 },
    { "Vector_ParseNode_op_index", (void*)Vector_ParseNode_op_index, "?", 1171 },
    { "Vector_ParseNode_op_index_set", (void*)Vector_ParseNode_op_index_set, "?", 1175 },
    { "Vector_ParseNode_data", (void*)Vector_ParseNode_data, "?", 1184 },
    { "Vector_ParseNode_capacity", (void*)Vector_ParseNode_capacity, "?", 1188 },
    { "Vector_ParseNode_as_slice", (void*)Vector_ParseNode_as_slice, "?", 1198 },
    { "String_new", (void*)String_new, "prelude.llpl", 476 },
    { "String_byte_len", (void*)String_byte_len, "prelude.llpl", 487 },
    { "String_len", (void*)String_len, "prelude.llpl", 491 },
    { "String_is_utf8", (void*)String_is_utf8, "prelude.llpl", 495 },
    { "String_byte_index", (void*)String_byte_index, "prelude.llpl", 499 },
    { "String_char_index", (void*)String_char_index, "prelude.llpl", 506 },
    { "String_codepoint_at", (void*)String_codepoint_at, "prelude.llpl", 513 },
    { "String_c_str", (void*)String_c_str, "prelude.llpl", 523 },
    { "String_byte_at", (void*)String_byte_at, "prelude.llpl", 527 },
    { "String_op_index", (void*)String_op_index, "prelude.llpl", 531 },
    { "String_iter_reset", (void*)String_iter_reset, "prelude.llpl", 539 },
    { "String_iter_has_next", (void*)String_iter_has_next, "prelude.llpl", 543 },
    { "String_iter_next", (void*)String_iter_next, "prelude.llpl", 547 },
    { "String_byte_set", (void*)String_byte_set, "prelude.llpl", 553 },
    { "String_op_eq_char_ptr", (void*)String_op_eq_char_ptr, "prelude.llpl", 557 },
    { "String_op_ne_char_ptr", (void*)String_op_ne_char_ptr, "prelude.llpl", 561 },
    { "String_op_lt_char_ptr", (void*)String_op_lt_char_ptr, "prelude.llpl", 565 },
    { "String_op_gt_char_ptr", (void*)String_op_gt_char_ptr, "prelude.llpl", 569 },
    { "String_op_eq_String", (void*)String_op_eq_String, "prelude.llpl", 580 },
    { "String_op_ne_String", (void*)String_op_ne_String, "prelude.llpl", 584 },
    { "String_op_lt_String", (void*)String_op_lt_String, "prelude.llpl", 588 },
    { "String_op_gt_String", (void*)String_op_gt_String, "prelude.llpl", 592 },
    { "String_op_add", (void*)String_op_add, "prelude.llpl", 602 },
    { "String_byte_substring", (void*)String_byte_substring, "prelude.llpl", 613 },
    { "String_substring", (void*)String_substring, "prelude.llpl", 634 },
    { "String_utf8_substring", (void*)String_utf8_substring, "prelude.llpl", 655 },
    { "String_byte_find", (void*)String_byte_find, "prelude.llpl", 660 },
    { "String_find", (void*)String_find, "prelude.llpl", 685 },
    { "String_contains", (void*)String_contains, "prelude.llpl", 693 },
    { "String_starts_with", (void*)String_starts_with, "prelude.llpl", 697 },
    { "String_ends_with", (void*)String_ends_with, "prelude.llpl", 712 },
    { "String_to_upper", (void*)String_to_upper, "prelude.llpl", 728 },
    { "String_to_lower", (void*)String_to_lower, "prelude.llpl", 744 },
    { "String_trim", (void*)String_trim, "prelude.llpl", 761 },
    { "Regex_new", (void*)Regex_new, "prelude.llpl", 383 },
    { "Regex_match", (void*)Regex_match, "prelude.llpl", 393 },
    { "Regex_captures", (void*)Regex_captures, "prelude.llpl", 397 },
    { "Regex_find_all", (void*)Regex_find_all, "prelude.llpl", 403 },
    { "Regex_replace", (void*)Regex_replace, "prelude.llpl", 410 },
    { "Regex_replace_all", (void*)Regex_replace_all, "prelude.llpl", 425 },
    { "Regex_source", (void*)Regex_source, "prelude.llpl", 446 },
    { "ReflectField_new", (void*)ReflectField_new, "prelude.llpl", 107 },
    { "ReflectField_exists", (void*)ReflectField_exists, "prelude.llpl", 113 },
    { "ReflectField_name", (void*)ReflectField_name, "prelude.llpl", 117 },
    { "ReflectField_type_name", (void*)ReflectField_type_name, "prelude.llpl", 121 },
    { "ReflectField_offset", (void*)ReflectField_offset, "prelude.llpl", 125 },
    { "ReflectField_size", (void*)ReflectField_size, "prelude.llpl", 129 },
    { "ParseNode_new", (void*)ParseNode_new, "prelude.llpl", 1332 },
    { "ParseNode_name", (void*)ParseNode_name, "prelude.llpl", 1344 },
    { "ParseNode_text", (void*)ParseNode_text, "prelude.llpl", 1348 },
    { "ParseNode_child", (void*)ParseNode_child, "prelude.llpl", 1352 },
    { "ParseNode_child_count", (void*)ParseNode_child_count, "prelude.llpl", 1356 },
    { "RegexMatch_new", (void*)RegexMatch_new, "prelude.llpl", 187 },
    { "RegexMatch_is_match", (void*)RegexMatch_is_match, "prelude.llpl", 205 },
    { "RegexMatch_group_count", (void*)RegexMatch_group_count, "prelude.llpl", 209 },
    { "RegexMatch_has_group", (void*)RegexMatch_has_group, "prelude.llpl", 213 },
    { "RegexMatch_group_start", (void*)RegexMatch_group_start, "prelude.llpl", 222 },
    { "RegexMatch_group_end", (void*)RegexMatch_group_end, "prelude.llpl", 234 },
    { "RegexMatch_group", (void*)RegexMatch_group, "prelude.llpl", 246 },
    { "RegexMatch_expand", (void*)RegexMatch_expand, "prelude.llpl", 261 },
    { "OwnedBuffer_new", (void*)OwnedBuffer_new, "prelude.llpl", 822 },
    { "OwnedBuffer_free", (void*)OwnedBuffer_free, "prelude.llpl", 831 },
    { "OwnedBuffer_data", (void*)OwnedBuffer_data, "prelude.llpl", 839 },
    { "OwnedBuffer_len", (void*)OwnedBuffer_len, "prelude.llpl", 843 },
    { "OwnedBuffer_is_null", (void*)OwnedBuffer_is_null, "prelude.llpl", 847 },
    { "OwnedBuffer_byte_at", (void*)OwnedBuffer_byte_at, "prelude.llpl", 851 },
    { "OwnedBuffer_set", (void*)OwnedBuffer_set, "prelude.llpl", 858 },
    { "OwnedBuffer_as_slice", (void*)OwnedBuffer_as_slice, "prelude.llpl", 865 },
    { "OwnedBuffer_take", (void*)OwnedBuffer_take, "prelude.llpl", 872 },
};
uint64_t llpl_symbol_table_count = 125;


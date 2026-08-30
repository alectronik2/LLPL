#include <stdint.h>
#include <stddef.h>
#include "runtime.h"

// Monomorphized generic instantiations - forward declarations
uint64_t int_hash(int64_t self);
int int_equals(int64_t self, int64_t other);
uint64_t uint_hash(uint64_t self);
int uint_equals(uint64_t self, uint64_t other);
uint64_t char_hash(char self);
int char_equals(char self, char other);
uint64_t char_ptr_hash(char* self);
int char_ptr_equals(char* self, char* other);
typedef struct String String;
uint64_t String_hash(String* self);
typedef struct String String;
int String_equals(String* self, String* other);
int64_t int_compare(int64_t self, int64_t other);
int64_t uint_compare(uint64_t self, uint64_t other);
int64_t char_compare(char self, char other);
int char_ptr_op_eq(char* self, char* other);
int char_ptr_op_ne(char* self, char* other);
int char_ptr_op_lt(char* self, char* other);
int char_ptr_op_gt(char* self, char* other);
int char_ptr_op_le(char* self, char* other);
int char_ptr_op_ge(char* self, char* other);
typedef struct Slice_char Slice_char;
typedef struct Result_int_char_ptr Result_int_char_ptr;
Result_int_char_ptr* Result_int_char_ptr_new();
void Result_int_char_ptr_destroy(void* ptr);
void Result_int_char_ptr_set_ok(Result_int_char_ptr* self, int64_t v);
void Result_int_char_ptr_set_err(Result_int_char_ptr* self, char* e);
void Result_int_char_ptr_set_err_with_trace(Result_int_char_ptr* self, char* e, char* t);
int64_t Result_int_char_ptr_get_ok(Result_int_char_ptr* self);
char* Result_int_char_ptr_get_err(Result_int_char_ptr* self);
char* Result_int_char_ptr_get_trace(Result_int_char_ptr* self);
int Result_int_char_ptr_is_ok(Result_int_char_ptr* self);
int Result_int_char_ptr_is_err(Result_int_char_ptr* self);
typedef struct Result_String_char_ptr Result_String_char_ptr;
typedef struct String String;
Result_String_char_ptr* Result_String_char_ptr_new();
void Result_String_char_ptr_destroy(void* ptr);
void Result_String_char_ptr_set_ok(Result_String_char_ptr* self, String* v);
void Result_String_char_ptr_set_err(Result_String_char_ptr* self, char* e);
void Result_String_char_ptr_set_err_with_trace(Result_String_char_ptr* self, char* e, char* t);
String* Result_String_char_ptr_get_ok(Result_String_char_ptr* self);
char* Result_String_char_ptr_get_err(Result_String_char_ptr* self);
char* Result_String_char_ptr_get_trace(Result_String_char_ptr* self);
int Result_String_char_ptr_is_ok(Result_String_char_ptr* self);
int Result_String_char_ptr_is_err(Result_String_char_ptr* self);

// Monomorphized generic instantiations - full bodies
struct Slice_char {
    char* ptr;
    uint64_t len;
};
struct Result_int_char_ptr {
    RefCount ref_count;
    int ok;
    int64_t value;
    char* error;
    char* trace;
};

Result_int_char_ptr* Result_int_char_ptr_new() {
    Result_int_char_ptr* self = (Result_int_char_ptr*)rc_alloc(sizeof(Result_int_char_ptr));
    if (!self) return NULL;
    rc_init(&self->ref_count);

    self->ok = 0;
    self->trace = NULL;
    return self;
}

void Result_int_char_ptr_destroy(void* ptr) {
    Result_int_char_ptr* self = (Result_int_char_ptr*)ptr;
}

void Result_int_char_ptr_set_ok(Result_int_char_ptr* self, int64_t v) {
    self->ok = 1;
    self->value = v;
}

void Result_int_char_ptr_set_err(Result_int_char_ptr* self, char* e) {
    self->ok = 0;
    self->error = e;
    self->trace = NULL;
}

void Result_int_char_ptr_set_err_with_trace(Result_int_char_ptr* self, char* e, char* t) {
    self->ok = 0;
    self->error = e;
    self->trace = t;
}

int64_t Result_int_char_ptr_get_ok(Result_int_char_ptr* self) {
    int64_t __llpl_ret30 = self->value;
    return __llpl_ret30;
}

char* Result_int_char_ptr_get_err(Result_int_char_ptr* self) {
    char* __llpl_ret31 = self->error;
    return __llpl_ret31;
}

char* Result_int_char_ptr_get_trace(Result_int_char_ptr* self) {
    char* __llpl_ret32 = self->trace;
    return __llpl_ret32;
}

int Result_int_char_ptr_is_ok(Result_int_char_ptr* self) {
    int __llpl_ret33 = self->ok;
    return __llpl_ret33;
}

int Result_int_char_ptr_is_err(Result_int_char_ptr* self) {
    int __llpl_ret34 = !self->ok;
    return __llpl_ret34;
}

struct Result_String_char_ptr {
    RefCount ref_count;
    int ok;
    String* value;
    char* error;
    char* trace;
};

Result_String_char_ptr* Result_String_char_ptr_new() {
    Result_String_char_ptr* self = (Result_String_char_ptr*)rc_alloc(sizeof(Result_String_char_ptr));
    if (!self) return NULL;
    rc_init(&self->ref_count);

    self->ok = 0;
    self->trace = NULL;
    return self;
}

void Result_String_char_ptr_destroy(void* ptr) {
    Result_String_char_ptr* self = (Result_String_char_ptr*)ptr;
    if (self->value) rc_release(self->value, String_destroy);
}

void Result_String_char_ptr_set_ok(Result_String_char_ptr* self, String* v) {
    self->ok = 1;
    self->value = v;
}

void Result_String_char_ptr_set_err(Result_String_char_ptr* self, char* e) {
    self->ok = 0;
    self->error = e;
    self->trace = NULL;
}

void Result_String_char_ptr_set_err_with_trace(Result_String_char_ptr* self, char* e, char* t) {
    self->ok = 0;
    self->error = e;
    self->trace = t;
}

String* Result_String_char_ptr_get_ok(Result_String_char_ptr* self) {
    String* __llpl_ret35 = self->value;
    return __llpl_ret35;
}

char* Result_String_char_ptr_get_err(Result_String_char_ptr* self) {
    char* __llpl_ret36 = self->error;
    return __llpl_ret36;
}

char* Result_String_char_ptr_get_trace(Result_String_char_ptr* self) {
    char* __llpl_ret37 = self->trace;
    return __llpl_ret37;
}

int Result_String_char_ptr_is_ok(Result_String_char_ptr* self) {
    int __llpl_ret38 = self->ok;
    return __llpl_ret38;
}

int Result_String_char_ptr_is_err(Result_String_char_ptr* self) {
    int __llpl_ret39 = !self->ok;
    return __llpl_ret39;
}


typedef struct EmbeddedFile EmbeddedFile;
typedef struct ReflectField ReflectField;
typedef struct ReflectType ReflectType;
typedef struct RegexMatch RegexMatch;
typedef struct RegexMatchIterator RegexMatchIterator;
typedef struct Regex Regex;
typedef struct String String;
typedef struct OwnedBuffer OwnedBuffer;
typedef struct std_io_File std_io_File;

extern int64_t ksnprintf(char* buf, uint64_t size, char* fmt, ...);
extern uint64_t llpl_strlen(char* s);
extern int64_t llpl_strcmp(char* a, char* b);
extern int llpl_utf8_valid(char* s);
extern uint64_t llpl_utf8_len(char* s);
extern uint64_t llpl_utf8_byte_offset(char* s, uint64_t char_index);
extern uint64_t llpl_utf8_char_index(char* s, uint64_t byte_offset);
extern uint64_t llpl_utf8_codepoint_at(char* s, uint64_t char_index);
extern int llpl_regex_match(char* pattern, char* text);
extern uint64_t llpl_regex_group_count(char* pattern);
extern int llpl_regex_capture_bounds(char* pattern, char* text, uint64_t group, int64_t* start, int64_t* end);
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
extern int rc_is_alive(char* ptr);
extern char* llpl_resolve_symbol(uint64_t addr);
extern char* llpl_symbol_name(char* symbol);
extern char* llpl_symbol_file(char* symbol);
extern int64_t llpl_symbol_line(char* symbol);
extern void llpl_panic(char* msg);
ReflectField* ReflectField_new(char* raw);
void ReflectField_destroy(void* ptr);
int ReflectField_exists(ReflectField* self);
char* ReflectField_name(ReflectField* self);
char* ReflectField_type_name(ReflectField* self);
int64_t ReflectField_offset(ReflectField* self);
int64_t ReflectField_size(ReflectField* self);
ReflectType* ReflectType_new(char* raw);
void ReflectType_destroy(void* ptr);
int ReflectType_exists(ReflectType* self);
char* ReflectType_name(ReflectType* self);
char* ReflectType_kind(ReflectType* self);
int64_t ReflectType_size(ReflectType* self);
int64_t ReflectType_field_count(ReflectType* self);
ReflectField* ReflectType_field(ReflectType* self, int64_t index);
ReflectType* reflect_type(char* name);
RegexMatch* RegexMatch_new(char* pattern, char* text, int64_t base_offset);
void RegexMatch_destroy(void* ptr);
int RegexMatch_is_match(RegexMatch* self);
int64_t RegexMatch_group_count(RegexMatch* self);
int RegexMatch_has_group(RegexMatch* self, int64_t index);
int64_t RegexMatch_group_start(RegexMatch* self, int64_t index);
int64_t RegexMatch_group_end(RegexMatch* self, int64_t index);
String* RegexMatch_group(RegexMatch* self, int64_t index);
String* RegexMatch_expand(RegexMatch* self, char* template);
RegexMatchIterator* RegexMatchIterator_new(char* pattern, char* text);
void RegexMatchIterator_destroy(void* ptr);
int RegexMatchIterator_advance(RegexMatchIterator* self);
int RegexMatchIterator_iter_has_next(RegexMatchIterator* self);
RegexMatch* RegexMatchIterator_iter_next(RegexMatchIterator* self);
Regex* Regex_new(char* pattern);
void Regex_destroy(void* ptr);
int Regex_match(Regex* self, char* text);
RegexMatch* Regex_captures(Regex* self, char* text);
RegexMatchIterator* Regex_find_all(Regex* self, char* text);
String* Regex_replace(Regex* self, char* text, char* replacement);
String* Regex_replace_all(Regex* self, char* text, char* replacement);
char* Regex_source(Regex* self);
String* String_new(char* s);
void String_destroy(void* ptr);
int64_t String_byte_len(String* self);
int64_t String_len(String* self);
int String_is_utf8(String* self);
int64_t String_byte_index(String* self, int64_t char_index);
int64_t String_char_index(String* self, int64_t byte_offset);
uint64_t String_codepoint_at(String* self, int64_t char_index);
char* String_c_str(String* self);
char String_byte_at(String* self, int64_t index);
uint64_t String_op_index(String* self, int64_t index);
void String_iter_reset(String* self);
int String_iter_has_next(String* self);
uint64_t String_iter_next(String* self);
void String_byte_set(String* self, int64_t index, char value);
int String_op_eq(String* self, char* other);
int String_op_ne(String* self, char* other);
int String_op_lt(String* self, char* other);
int String_op_gt(String* self, char* other);
String* String_op_add(String* self, char* other);
String* String_byte_substring(String* self, int64_t start, int64_t count);
String* String_substring(String* self, int64_t start, int64_t count);
String* String_utf8_substring(String* self, int64_t start, int64_t count);
int64_t String_byte_find(String* self, char* needle);
int64_t String_find(String* self, char* needle);
int String_contains(String* self, char* needle);
int String_starts_with(String* self, char* prefix);
int String_ends_with(String* self, char* suffix);
String* String_to_upper(String* self);
String* String_to_lower(String* self);
String* String_trim(String* self);
OwnedBuffer* OwnedBuffer_new(uint64_t size);
void OwnedBuffer_destroy(void* ptr);
void OwnedBuffer_free(OwnedBuffer* self);
char* OwnedBuffer_data(OwnedBuffer* self);
uint64_t OwnedBuffer_len(OwnedBuffer* self);
int OwnedBuffer_is_null(OwnedBuffer* self);
char OwnedBuffer_byte_at(OwnedBuffer* self, uint64_t index);
void OwnedBuffer_set(OwnedBuffer* self, uint64_t index, char value);
Slice_char OwnedBuffer_as_slice(OwnedBuffer* self);
char* OwnedBuffer_take(OwnedBuffer* self);
extern int64_t open(char* path, int64_t flags, int64_t mode);
extern int64_t close(int64_t fd);
extern int64_t read(int64_t fd, char* buf, uint64_t count);
extern int64_t write(int64_t fd, char* buf, uint64_t count);
extern int64_t lseek(int64_t fd, int64_t offset, int64_t whence);
extern int64_t unlink(char* path);
extern int64_t rename(char* oldpath, char* newpath);
std_io_File* std_io_File_new_char_ptr_int(char* filepath, int64_t flags);
std_io_File* std_io_File_new_char_ptr_int_int(char* filepath, int64_t flags, int64_t mode);
void std_io_File_destroy(void* ptr);
int std_io_File_is_valid(std_io_File* self);
Result_int_char_ptr* std_io_File_read_bytes(std_io_File* self, char* buffer, uint64_t size);
Result_int_char_ptr* std_io_File_write_bytes(std_io_File* self, char* buffer, uint64_t size);
Result_String_char_ptr* std_io_File_read_string(std_io_File* self, uint64_t max_size);
Result_int_char_ptr* std_io_File_write_string(std_io_File* self, String* s);
Result_int_char_ptr* std_io_File_seek(std_io_File* self, int64_t offset, int64_t whence);
Result_int_char_ptr* std_io_File_tell(std_io_File* self);
Result_int_char_ptr* std_io_File_size(std_io_File* self);
Result_String_char_ptr* std_io_File_read_all(std_io_File* self);
int std_io_File_flush(std_io_File* self);
Result_String_char_ptr* std_io_read_file(char* path);
Result_int_char_ptr* std_io_write_file(char* path, String* content);
Result_int_char_ptr* std_io_append_file(char* path, String* content);
int std_io_file_exists(char* path);
int std_io_delete_file(char* path);
int std_io_rename_file(char* oldpath, char* newpath);

extern const int64_t std_io_O_RDONLY;
extern const int64_t std_io_O_WRONLY;
extern const int64_t std_io_O_RDWR;
extern const int64_t std_io_O_CREAT;
extern const int64_t std_io_O_TRUNC;
extern const int64_t std_io_O_APPEND;
extern const int64_t std_io_SEEK_SET;
extern const int64_t std_io_SEEK_CUR;
extern const int64_t std_io_SEEK_END;
extern const int64_t std_io_ERR_FILE_NOT_FOUND;
extern const int64_t std_io_ERR_PERMISSION_DENIED;
extern const int64_t std_io_ERR_IO_ERROR;


// Module: /home/nix/Claude/LLPL/prelude.llpl
extern int64_t ksnprintf(char* buf, uint64_t size, char* fmt, ...);

extern uint64_t llpl_strlen(char* s);

extern int64_t llpl_strcmp(char* a, char* b);

extern int llpl_utf8_valid(char* s);

extern uint64_t llpl_utf8_len(char* s);

extern uint64_t llpl_utf8_byte_offset(char* s, uint64_t char_index);

extern uint64_t llpl_utf8_char_index(char* s, uint64_t byte_offset);

extern uint64_t llpl_utf8_codepoint_at(char* s, uint64_t char_index);

extern int llpl_regex_match(char* pattern, char* text);

extern uint64_t llpl_regex_group_count(char* pattern);

extern int llpl_regex_capture_bounds(char* pattern, char* text, uint64_t group, int64_t* start, int64_t* end);

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

extern int rc_is_alive(char* ptr);

extern char* llpl_resolve_symbol(uint64_t addr);

extern char* llpl_symbol_name(char* symbol);

extern char* llpl_symbol_file(char* symbol);

extern int64_t llpl_symbol_line(char* symbol);

extern void llpl_panic(char* msg);

struct EmbeddedFile {
    char* data;
    uint64_t len;
};

struct ReflectField {
    RefCount ref_count;
    char* raw;
};

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

int ReflectField_exists(ReflectField* self) {
    int __llpl_ret40 = (((uint64_t)self->raw) != 0);
    return __llpl_ret40;
}

char* ReflectField_name(ReflectField* self) {
    char* __llpl_ret41 = llpl_reflect_field_name(self->raw);
    return __llpl_ret41;
}

char* ReflectField_type_name(ReflectField* self) {
    char* __llpl_ret42 = llpl_reflect_field_type_name(self->raw);
    return __llpl_ret42;
}

int64_t ReflectField_offset(ReflectField* self) {
    int64_t __llpl_ret43 = ((int64_t)llpl_reflect_field_offset(self->raw));
    return __llpl_ret43;
}

int64_t ReflectField_size(ReflectField* self) {
    int64_t __llpl_ret44 = ((int64_t)llpl_reflect_field_size(self->raw));
    return __llpl_ret44;
}


struct ReflectType {
    RefCount ref_count;
    char* raw;
};

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

int ReflectType_exists(ReflectType* self) {
    int __llpl_ret45 = (((uint64_t)self->raw) != 0);
    return __llpl_ret45;
}

char* ReflectType_name(ReflectType* self) {
    char* __llpl_ret46 = llpl_reflect_type_name(self->raw);
    return __llpl_ret46;
}

char* ReflectType_kind(ReflectType* self) {
    char* __llpl_ret47 = llpl_reflect_type_kind(self->raw);
    return __llpl_ret47;
}

int64_t ReflectType_size(ReflectType* self) {
    int64_t __llpl_ret48 = ((int64_t)llpl_reflect_type_size(self->raw));
    return __llpl_ret48;
}

int64_t ReflectType_field_count(ReflectType* self) {
    int64_t __llpl_ret49 = ((int64_t)llpl_reflect_field_count(self->raw));
    return __llpl_ret49;
}

ReflectField* ReflectType_field(ReflectType* self, int64_t index) {
    if ((index < 0)) {
        ReflectField* __llpl_ret50 = ReflectField_new(NULL);
        return __llpl_ret50;
    }
    ReflectField* __llpl_ret51 = ReflectField_new(llpl_reflect_field(self->raw, ((uint64_t)index)));
    return __llpl_ret51;
}


ReflectType* reflect_type(char* name) {
    ReflectType* __llpl_ret52 = ReflectType_new(llpl_reflect_type(name));
    return __llpl_ret52;
}

struct RegexMatch {
    RefCount ref_count;
    int matched;
    char* pattern;
    char* text;
    int64_t base_offset;
};

RegexMatch* RegexMatch_new(char* pattern, char* text, int64_t base_offset) {
    RegexMatch* self = (RegexMatch*)rc_alloc(sizeof(RegexMatch));
    if (!self) return NULL;
    rc_init(&self->ref_count);

    int64_t pattern_len = ((int64_t)llpl_strlen(pattern));
    self->pattern = llpl_alloc(((uint64_t)(pattern_len + 1)));
    llpl_memcpy(self->pattern, pattern, ((uint64_t)(pattern_len + 1)));
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

int RegexMatch_is_match(RegexMatch* self) {
    int __llpl_ret53 = self->matched;
    return __llpl_ret53;
}

int64_t RegexMatch_group_count(RegexMatch* self) {
    int64_t __llpl_ret54 = ((int64_t)llpl_regex_group_count(self->pattern));
    return __llpl_ret54;
}

int RegexMatch_has_group(RegexMatch* self, int64_t index) {
    if ((index < 0)) {
        int __llpl_ret55 = 0;
        return __llpl_ret55;
    }
    int64_t start = 0;
    int64_t end = 0;
    int __llpl_ret56 = llpl_regex_capture_bounds(self->pattern, self->text, ((uint64_t)index), &start, &end);
    return __llpl_ret56;
}

int64_t RegexMatch_group_start(RegexMatch* self, int64_t index) {
    if ((index < 0)) {
        int64_t __llpl_ret57 = -1;
        return __llpl_ret57;
    }
    int64_t start = 0;
    int64_t end = 0;
    if (llpl_regex_capture_bounds(self->pattern, self->text, ((uint64_t)index), &start, &end)) {
        int64_t __llpl_ret58 = (start + self->base_offset);
        return __llpl_ret58;
    }
    int64_t __llpl_ret59 = -1;
    return __llpl_ret59;
}

int64_t RegexMatch_group_end(RegexMatch* self, int64_t index) {
    if ((index < 0)) {
        int64_t __llpl_ret60 = -1;
        return __llpl_ret60;
    }
    int64_t start = 0;
    int64_t end = 0;
    if (llpl_regex_capture_bounds(self->pattern, self->text, ((uint64_t)index), &start, &end)) {
        int64_t __llpl_ret61 = (end + self->base_offset);
        return __llpl_ret61;
    }
    int64_t __llpl_ret62 = -1;
    return __llpl_ret62;
}

String* RegexMatch_group(RegexMatch* self, int64_t index) {
    if ((index < 0)) {
        String* __llpl_ret63 = String_new("");
        return __llpl_ret63;
    }
    char* raw = llpl_regex_capture(self->pattern, self->text, ((uint64_t)index));
    String* out = String_new(raw);
    llpl_free(raw);
    String* __llpl_ret64 = out;
    return __llpl_ret64;
}

String* RegexMatch_expand(RegexMatch* self, char* template) {
    String* ts = String_new(template);
    String* result = String_new("");
    int64_t len = String_byte_len(ts);
    int64_t lit_start = 0;
    int64_t i = 0;
    while ((i < len)) {
        if (((String_byte_at(ts, i) == 36) && ((i + 1) < len))) {
            if ((i > lit_start)) {
                result = String_op_add(result, String_c_str(String_byte_substring(ts, lit_start, (i - lit_start))));
            }
            char next = String_byte_at(ts, (i + 1));
            if ((next == 36)) {
                result = String_op_add(result, "$");
                i = (i + 2);
            } else {
                if (((next >= 48) && (next <= 57))) {
                    int64_t group_index = (((int64_t)next) - 48);
                    int64_t j = (i + 2);
                    while ((((j < len) && (String_byte_at(ts, j) >= 48)) && (String_byte_at(ts, j) <= 57))) {
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
    String* __llpl_ret65 = result;
    return __llpl_ret65;
}


struct RegexMatchIterator {
    RefCount ref_count;
    char* pattern;
    char* text;
    int64_t text_len;
    int64_t pos;
    RegexMatch* current;
    int has_current;
    int done;
};

RegexMatchIterator* RegexMatchIterator_new(char* pattern, char* text) {
    RegexMatchIterator* self = (RegexMatchIterator*)rc_alloc(sizeof(RegexMatchIterator));
    if (!self) return NULL;
    rc_init(&self->ref_count);

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

int RegexMatchIterator_advance(RegexMatchIterator* self) {
    if ((self->done || (self->pos > self->text_len))) {
        self->done = 1;
        int __llpl_ret66 = 0;
        return __llpl_ret66;
    }
    RegexMatch* m = RegexMatch_new(self->pattern, (self->text + self->pos), self->pos);
    if (!RegexMatch_is_match(m)) {
        self->done = 1;
        int __llpl_ret67 = 0;
        return __llpl_ret67;
    }
    self->current = m;
    int64_t end_in_suffix = (RegexMatch_group_end(m, 0) - self->pos);
    int64_t start_in_suffix = (RegexMatch_group_start(m, 0) - self->pos);
    if ((end_in_suffix == start_in_suffix)) {
        self->pos = ((self->pos + end_in_suffix) + 1);
    } else {
        self->pos = (self->pos + end_in_suffix);
    }
    int __llpl_ret68 = 1;
    return __llpl_ret68;
}

int RegexMatchIterator_iter_has_next(RegexMatchIterator* self) {
    if (self->has_current) {
        int __llpl_ret69 = 1;
        return __llpl_ret69;
    }
    self->has_current = RegexMatchIterator_advance(self);
    int __llpl_ret70 = self->has_current;
    return __llpl_ret70;
}

RegexMatch* RegexMatchIterator_iter_next(RegexMatchIterator* self) {
    if (!self->has_current) {
        RegexMatchIterator_advance(self);
    }
    self->has_current = 0;
    RegexMatch* __llpl_ret71 = self->current;
    return __llpl_ret71;
}


struct Regex {
    RefCount ref_count;
    char* pattern;
};

Regex* Regex_new(char* pattern) {
    Regex* self = (Regex*)rc_alloc(sizeof(Regex));
    if (!self) return NULL;
    rc_init(&self->ref_count);

    int64_t len = ((int64_t)llpl_strlen(pattern));
    self->pattern = llpl_alloc(((uint64_t)(len + 1)));
    llpl_memcpy(self->pattern, pattern, ((uint64_t)(len + 1)));
    return self;
}

void Regex_destroy(void* ptr) {
    Regex* self = (Regex*)ptr;
    llpl_free(self->pattern);
}

int Regex_match(Regex* self, char* text) {
    int __llpl_ret72 = llpl_regex_match(self->pattern, text);
    return __llpl_ret72;
}

RegexMatch* Regex_captures(Regex* self, char* text) {
    RegexMatch* __llpl_ret73 = RegexMatch_new(self->pattern, text, 0);
    return __llpl_ret73;
}

RegexMatchIterator* Regex_find_all(Regex* self, char* text) {
    RegexMatchIterator* __llpl_ret74 = RegexMatchIterator_new(self->pattern, text);
    return __llpl_ret74;
}

String* Regex_replace(Regex* self, char* text, char* replacement) {
    RegexMatch* m = Regex_captures(self, text);
    if (!RegexMatch_is_match(m)) {
        String* __llpl_ret75 = String_new(text);
        return __llpl_ret75;
    }
    String* ts = String_new(text);
    int64_t start = RegexMatch_group_start(m, 0);
    int64_t end = RegexMatch_group_end(m, 0);
    String* result = String_byte_substring(ts, 0, start);
    result = String_op_add(result, String_c_str(RegexMatch_expand(m, replacement)));
    result = String_op_add(result, String_c_str(String_byte_substring(ts, end, (String_byte_len(ts) - end))));
    String* __llpl_ret76 = result;
    return __llpl_ret76;
}

String* Regex_replace_all(Regex* self, char* text, char* replacement) {
    String* ts = String_new(text);
    String* result = String_new("");
    RegexMatchIterator* it = Regex_find_all(self, text);
    int64_t last_end = 0;
    while (RegexMatchIterator_iter_has_next(it)) {
        RegexMatch* m = RegexMatchIterator_iter_next(it);
        int64_t start = RegexMatch_group_start(m, 0);
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
    String* __llpl_ret77 = result;
    return __llpl_ret77;
}

char* Regex_source(Regex* self) {
    char* __llpl_ret78 = self->pattern;
    return __llpl_ret78;
}


struct String {
    RefCount ref_count;
    char* buf;
    int64_t length;
    int64_t iter_pos;
};

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
    int64_t __llpl_ret79 = self->length;
    return __llpl_ret79;
}

int64_t String_len(String* self) {
    int64_t __llpl_ret80 = ((int64_t)llpl_utf8_len(self->buf));
    return __llpl_ret80;
}

int String_is_utf8(String* self) {
    int __llpl_ret81 = llpl_utf8_valid(self->buf);
    return __llpl_ret81;
}

int64_t String_byte_index(String* self, int64_t char_index) {
    if ((char_index < 0)) {
        int64_t __llpl_ret82 = 0;
        return __llpl_ret82;
    }
    int64_t __llpl_ret83 = ((int64_t)llpl_utf8_byte_offset(self->buf, ((uint64_t)char_index)));
    return __llpl_ret83;
}

int64_t String_char_index(String* self, int64_t byte_offset) {
    if ((byte_offset < 0)) {
        int64_t __llpl_ret84 = 0;
        return __llpl_ret84;
    }
    int64_t __llpl_ret85 = ((int64_t)llpl_utf8_char_index(self->buf, ((uint64_t)byte_offset)));
    return __llpl_ret85;
}

uint64_t String_codepoint_at(String* self, int64_t char_index) {
    if ((char_index < 0)) {
        uint64_t __llpl_ret86 = 0;
        return __llpl_ret86;
    }
    uint64_t __llpl_ret87 = llpl_utf8_codepoint_at(self->buf, ((uint64_t)char_index));
    return __llpl_ret87;
}

char* String_c_str(String* self) {
    char* __llpl_ret88 = self->buf;
    return __llpl_ret88;
}

char String_byte_at(String* self, int64_t index) {
    char __llpl_ret89 = self->buf[index];
    return __llpl_ret89;
}

uint64_t String_op_index(String* self, int64_t index) {
    uint64_t __llpl_ret90 = String_codepoint_at(self, index);
    return __llpl_ret90;
}

void String_iter_reset(String* self) {
    self->iter_pos = 0;
}

int String_iter_has_next(String* self) {
    int __llpl_ret91 = (self->iter_pos < String_len(self));
    return __llpl_ret91;
}

uint64_t String_iter_next(String* self) {
    uint64_t c = String_codepoint_at(self, self->iter_pos);
    self->iter_pos = (self->iter_pos + 1);
    uint64_t __llpl_ret92 = c;
    return __llpl_ret92;
}

void String_byte_set(String* self, int64_t index, char value) {
    self->buf[index] = value;
}

int String_op_eq(String* self, char* other) {
    int __llpl_ret93 = (llpl_strcmp(self->buf, other) == 0);
    return __llpl_ret93;
}

int String_op_ne(String* self, char* other) {
    int __llpl_ret94 = !String_op_eq(self, other);
    return __llpl_ret94;
}

int String_op_lt(String* self, char* other) {
    int __llpl_ret95 = (llpl_strcmp(self->buf, other) < 0);
    return __llpl_ret95;
}

int String_op_gt(String* self, char* other) {
    int __llpl_ret96 = (llpl_strcmp(self->buf, other) > 0);
    return __llpl_ret96;
}

String* String_op_add(String* self, char* other) {
    int64_t other_len = ((int64_t)llpl_strlen(other));
    int64_t total = (self->length + other_len);
    char* joined = llpl_alloc(((uint64_t)(total + 1)));
    llpl_memcpy(joined, self->buf, ((uint64_t)self->length));
    llpl_memcpy((joined + self->length), other, ((uint64_t)(other_len + 1)));
    String* __llpl_ret97 = String_new(joined);
    return __llpl_ret97;
}

String* String_byte_substring(String* self, int64_t start, int64_t count) {
    if ((start < 0)) {
        start = 0;
    }
    if ((start > self->length)) {
        start = self->length;
    }
    int64_t max_count = (self->length - start);
    if ((count > max_count)) {
        count = max_count;
    }
    if ((count < 0)) {
        count = 0;
    }
    char* piece = llpl_alloc(((uint64_t)(count + 1)));
    llpl_memcpy(piece, (self->buf + start), ((uint64_t)count));
    piece[count] = 0;
    String* __llpl_ret98 = String_new(piece);
    return __llpl_ret98;
}

String* String_substring(String* self, int64_t start, int64_t count) {
    if ((start < 0)) {
        start = 0;
    }
    int64_t total_chars = String_len(self);
    if ((start > total_chars)) {
        start = total_chars;
    }
    int64_t max_count = (total_chars - start);
    if ((count > max_count)) {
        count = max_count;
    }
    if ((count < 0)) {
        count = 0;
    }
    int64_t byte_start = String_byte_index(self, start);
    int64_t byte_end = String_byte_index(self, (start + count));
    String* __llpl_ret99 = String_byte_substring(self, byte_start, (byte_end - byte_start));
    return __llpl_ret99;
}

String* String_utf8_substring(String* self, int64_t start, int64_t count) {
    String* __llpl_ret100 = String_substring(self, start, count);
    return __llpl_ret100;
}

int64_t String_byte_find(String* self, char* needle) {
    int64_t needle_len = ((int64_t)llpl_strlen(needle));
    if ((needle_len == 0)) {
        int64_t __llpl_ret101 = 0;
        return __llpl_ret101;
    }
    int64_t i = 0;
    while ((i <= (self->length - needle_len))) {
        int64_t j = 0;
        int matched = 1;
        while (((j < needle_len) && matched)) {
            if ((self->buf[(i + j)] != needle[j])) {
                matched = 0;
            }
            j = (j + 1);
        }
        if (matched) {
            int64_t __llpl_ret102 = i;
            return __llpl_ret102;
        }
        i = (i + 1);
    }
    int64_t __llpl_ret103 = -1;
    return __llpl_ret103;
}

int64_t String_find(String* self, char* needle) {
    int64_t byte_pos = String_byte_find(self, needle);
    if ((byte_pos < 0)) {
        int64_t __llpl_ret104 = -1;
        return __llpl_ret104;
    }
    int64_t __llpl_ret105 = String_char_index(self, byte_pos);
    return __llpl_ret105;
}

int String_contains(String* self, char* needle) {
    int __llpl_ret106 = (String_find(self, needle) >= 0);
    return __llpl_ret106;
}

int String_starts_with(String* self, char* prefix) {
    int64_t prefix_len = ((int64_t)llpl_strlen(prefix));
    if ((prefix_len > self->length)) {
        int __llpl_ret107 = 0;
        return __llpl_ret107;
    }
    int64_t i = 0;
    while ((i < prefix_len)) {
        if ((self->buf[i] != prefix[i])) {
            int __llpl_ret108 = 0;
            return __llpl_ret108;
        }
        i = (i + 1);
    }
    int __llpl_ret109 = 1;
    return __llpl_ret109;
}

int String_ends_with(String* self, char* suffix) {
    int64_t suffix_len = ((int64_t)llpl_strlen(suffix));
    if ((suffix_len > self->length)) {
        int __llpl_ret110 = 0;
        return __llpl_ret110;
    }
    int64_t offset = (self->length - suffix_len);
    int64_t i = 0;
    while ((i < suffix_len)) {
        if ((self->buf[(offset + i)] != suffix[i])) {
            int __llpl_ret111 = 0;
            return __llpl_ret111;
        }
        i = (i + 1);
    }
    int __llpl_ret112 = 1;
    return __llpl_ret112;
}

String* String_to_upper(String* self) {
    char* out = llpl_alloc(((uint64_t)(self->length + 1)));
    int64_t i = 0;
    while ((i < self->length)) {
        char c = self->buf[i];
        if (((c >= 97) && (c <= 122))) {
            out[i] = ((char)(((int64_t)c) - 32));
        } else {
            out[i] = c;
        }
        i = (i + 1);
    }
    out[self->length] = 0;
    String* __llpl_ret113 = String_new(out);
    return __llpl_ret113;
}

String* String_to_lower(String* self) {
    char* out = llpl_alloc(((uint64_t)(self->length + 1)));
    int64_t i = 0;
    while ((i < self->length)) {
        char c = self->buf[i];
        if (((c >= 65) && (c <= 90))) {
            out[i] = ((char)(((int64_t)c) + 32));
        } else {
            out[i] = c;
        }
        i = (i + 1);
    }
    out[self->length] = 0;
    String* __llpl_ret114 = String_new(out);
    return __llpl_ret114;
}

String* String_trim(String* self) {
    int64_t start = 0;
    while (((start < self->length) && ((((self->buf[start] == 32) || (self->buf[start] == 9)) || (self->buf[start] == 10)) || (self->buf[start] == 13)))) {
        start = (start + 1);
    }
    int64_t end = self->length;
    while (((end > start) && ((((self->buf[(end - 1)] == 32) || (self->buf[(end - 1)] == 9)) || (self->buf[(end - 1)] == 10)) || (self->buf[(end - 1)] == 13)))) {
        end = (end - 1);
    }
    String* __llpl_ret115 = String_byte_substring(self, start, (end - start));
    return __llpl_ret115;
}


struct OwnedBuffer {
    RefCount ref_count;
    char* ptr;
    uint64_t length;
};

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
    if (char_ptr_op_ne(self->ptr, NULL)) {
        llpl_free(self->ptr);
        self->ptr = NULL;
        self->length = 0;
    }
}

char* OwnedBuffer_data(OwnedBuffer* self) {
    char* __llpl_ret116 = self->ptr;
    return __llpl_ret116;
}

uint64_t OwnedBuffer_len(OwnedBuffer* self) {
    uint64_t __llpl_ret117 = self->length;
    return __llpl_ret117;
}

int OwnedBuffer_is_null(OwnedBuffer* self) {
    int __llpl_ret118 = char_ptr_op_eq(self->ptr, NULL);
    return __llpl_ret118;
}

char OwnedBuffer_byte_at(OwnedBuffer* self, uint64_t index) {
    if ((index >= self->length)) {
        llpl_panic("OwnedBuffer.byte_at: index out of bounds");
    }
    char __llpl_ret119 = self->ptr[((int64_t)index)];
    return __llpl_ret119;
}

void OwnedBuffer_set(OwnedBuffer* self, uint64_t index, char value) {
    if ((index >= self->length)) {
        llpl_panic("OwnedBuffer.set: index out of bounds");
    }
    self->ptr[((int64_t)index)] = value;
}

Slice_char OwnedBuffer_as_slice(OwnedBuffer* self) {
    Slice_char s;
    s.ptr = self->ptr;
    s.len = self->length;
    Slice_char __llpl_ret120 = s;
    return __llpl_ret120;
}

char* OwnedBuffer_take(OwnedBuffer* self) {
    char* out = self->ptr;
    self->ptr = NULL;
    self->length = 0;
    char* __llpl_ret121 = out;
    return __llpl_ret121;
}


// Module: /home/nix/Claude/LLPL/stdlib/io/file.llpl
const int64_t std_io_O_RDONLY = 0;

const int64_t std_io_O_WRONLY = 1;

const int64_t std_io_O_RDWR = 2;

const int64_t std_io_O_CREAT = 64;

const int64_t std_io_O_TRUNC = 512;

const int64_t std_io_O_APPEND = 1024;

const int64_t std_io_SEEK_SET = 0;

const int64_t std_io_SEEK_CUR = 1;

const int64_t std_io_SEEK_END = 2;

const int64_t std_io_ERR_FILE_NOT_FOUND = -1;

const int64_t std_io_ERR_PERMISSION_DENIED = -2;

const int64_t std_io_ERR_IO_ERROR = -3;

extern int64_t open(char* path, int64_t flags, int64_t mode);

extern int64_t close(int64_t fd);

extern int64_t read(int64_t fd, char* buf, uint64_t count);

extern int64_t write(int64_t fd, char* buf, uint64_t count);

extern int64_t lseek(int64_t fd, int64_t offset, int64_t whence);

extern int64_t unlink(char* path);

extern int64_t rename(char* oldpath, char* newpath);

struct std_io_File {
    RefCount ref_count;
    int64_t fd;
    String* path;
    int is_open;
};

std_io_File* std_io_File_new_char_ptr_int(char* filepath, int64_t flags) {
    std_io_File* self = (std_io_File*)rc_alloc(sizeof(std_io_File));
    if (!self) return NULL;
    rc_init(&self->ref_count);

    self->path = String_new(filepath);
    self->fd = open(filepath, flags, 420);
    self->is_open = (self->fd >= 0);
    return self;
}

std_io_File* std_io_File_new_char_ptr_int_int(char* filepath, int64_t flags, int64_t mode) {
    std_io_File* self = (std_io_File*)rc_alloc(sizeof(std_io_File));
    if (!self) return NULL;
    rc_init(&self->ref_count);

    self->path = String_new(filepath);
    self->fd = open(filepath, flags, mode);
    self->is_open = (self->fd >= 0);
    return self;
}

void std_io_File_destroy(void* ptr) {
    std_io_File* self = (std_io_File*)ptr;
    if (self->is_open) {
        close(self->fd);
    }
    if (self->path) rc_release(self->path, String_destroy);
}

int std_io_File_is_valid(std_io_File* self) {
    int __llpl_ret122 = self->is_open;
    return __llpl_ret122;
}

Result_int_char_ptr* std_io_File_read_bytes(std_io_File* self, char* buffer, uint64_t size) {
    Result_int_char_ptr* result = Result_int_char_ptr_new();
    if (!self->is_open) {
        Result_int_char_ptr_set_err(result, "File not open");
        Result_int_char_ptr* __llpl_ret123 = result;
        return __llpl_ret123;
    }
    int64_t bytes_read = read(self->fd, buffer, size);
    if ((bytes_read < 0)) {
        Result_int_char_ptr_set_err(result, "Read error");
    } else {
        Result_int_char_ptr_set_ok(result, bytes_read);
    }
    Result_int_char_ptr* __llpl_ret124 = result;
    return __llpl_ret124;
}

Result_int_char_ptr* std_io_File_write_bytes(std_io_File* self, char* buffer, uint64_t size) {
    Result_int_char_ptr* result = Result_int_char_ptr_new();
    if (!self->is_open) {
        Result_int_char_ptr_set_err(result, "File not open");
        Result_int_char_ptr* __llpl_ret125 = result;
        return __llpl_ret125;
    }
    int64_t bytes_written = write(self->fd, buffer, size);
    if ((bytes_written < 0)) {
        Result_int_char_ptr_set_err(result, "Write error");
    } else {
        Result_int_char_ptr_set_ok(result, bytes_written);
    }
    Result_int_char_ptr* __llpl_ret126 = result;
    return __llpl_ret126;
}

Result_String_char_ptr* std_io_File_read_string(std_io_File* self, uint64_t max_size) {
    Result_String_char_ptr* result = Result_String_char_ptr_new();
    if (!self->is_open) {
        Result_String_char_ptr_set_err(result, "File not open");
        Result_String_char_ptr* __llpl_ret127 = result;
        return __llpl_ret127;
    }
    char* buffer = ((char*)malloc((max_size + 1)));
    int64_t bytes_read = read(self->fd, buffer, max_size);
    if ((bytes_read < 0)) {
        free(((void*)buffer));
        Result_String_char_ptr_set_err(result, "Read error");
        Result_String_char_ptr* __llpl_ret128 = result;
        return __llpl_ret128;
    }
    buffer[bytes_read] = 0;
    String* s = String_new(buffer);
    free(((void*)buffer));
    Result_String_char_ptr_set_ok(result, s);
    Result_String_char_ptr* __llpl_ret129 = result;
    return __llpl_ret129;
}

Result_int_char_ptr* std_io_File_write_string(std_io_File* self, String* s) {
    Result_int_char_ptr* __llpl_ret130 = std_io_File_write_bytes(self, String_c_str(s), ((uint64_t)String_length(s)));
    return __llpl_ret130;
}

Result_int_char_ptr* std_io_File_seek(std_io_File* self, int64_t offset, int64_t whence) {
    Result_int_char_ptr* result = Result_int_char_ptr_new();
    if (!self->is_open) {
        Result_int_char_ptr_set_err(result, "File not open");
        Result_int_char_ptr* __llpl_ret131 = result;
        return __llpl_ret131;
    }
    int64_t pos = lseek(self->fd, offset, whence);
    if ((pos < 0)) {
        Result_int_char_ptr_set_err(result, "Seek error");
    } else {
        Result_int_char_ptr_set_ok(result, pos);
    }
    Result_int_char_ptr* __llpl_ret132 = result;
    return __llpl_ret132;
}

Result_int_char_ptr* std_io_File_tell(std_io_File* self) {
    Result_int_char_ptr* __llpl_ret133 = std_io_File_seek(self, 0, std_io_SEEK_CUR);
    return __llpl_ret133;
}

Result_int_char_ptr* std_io_File_size(std_io_File* self) {
    Result_int_char_ptr* current_pos_result = std_io_File_tell(self);
    if (!Result_int_char_ptr_is_ok(current_pos_result)) {
        Result_int_char_ptr* __llpl_ret134 = current_pos_result;
        return __llpl_ret134;
    }
    int64_t current_pos = Result_int_char_ptr_unwrap(current_pos_result);
    Result_int_char_ptr* end_pos_result = std_io_File_seek(self, 0, std_io_SEEK_END);
    if (!Result_int_char_ptr_is_ok(end_pos_result)) {
        Result_int_char_ptr* __llpl_ret135 = end_pos_result;
        return __llpl_ret135;
    }
    int64_t file_size = Result_int_char_ptr_unwrap(end_pos_result);
    std_io_File_seek(self, current_pos, std_io_SEEK_SET);
    Result_int_char_ptr* result = Result_int_char_ptr_new();
    Result_int_char_ptr_set_ok(result, file_size);
    Result_int_char_ptr* __llpl_ret136 = result;
    return __llpl_ret136;
}

Result_String_char_ptr* std_io_File_read_all(std_io_File* self) {
    Result_int_char_ptr* size_result = std_io_File_size(self);
    if (!Result_int_char_ptr_is_ok(size_result)) {
        Result_String_char_ptr* result = Result_String_char_ptr_new();
        Result_String_char_ptr_set_err(result, "Cannot get file size");
        Result_String_char_ptr* __llpl_ret137 = result;
        return __llpl_ret137;
    }
    int64_t file_size = Result_int_char_ptr_unwrap(size_result);
    std_io_File_seek(self, 0, std_io_SEEK_SET);
    Result_String_char_ptr* __llpl_ret138 = std_io_File_read_string(self, ((uint64_t)file_size));
    return __llpl_ret138;
}

int std_io_File_flush(std_io_File* self) {
    int __llpl_ret139 = 1;
    return __llpl_ret139;
}


Result_String_char_ptr* std_io_read_file(char* path) {
    std_io_File* f = std_io_File_new_char_ptr_int(path, std_io_O_RDONLY);
    Result_String_char_ptr* result = Result_String_char_ptr_new();
    if (!std_io_File_is_valid(f)) {
        Result_String_char_ptr_set_err(result, "Cannot open file");
        Result_String_char_ptr* __llpl_ret140 = result;
        return __llpl_ret140;
    }
    Result_String_char_ptr* __llpl_ret141 = std_io_File_read_all(f);
    return __llpl_ret141;
}

Result_int_char_ptr* std_io_write_file(char* path, String* content) {
    std_io_File* f = std_io_File_new_char_ptr_int(path, ((std_io_O_WRONLY | std_io_O_CREAT) | std_io_O_TRUNC));
    Result_int_char_ptr* result = Result_int_char_ptr_new();
    if (!std_io_File_is_valid(f)) {
        Result_int_char_ptr_set_err(result, "Cannot open file");
        Result_int_char_ptr* __llpl_ret142 = result;
        return __llpl_ret142;
    }
    Result_int_char_ptr* __llpl_ret143 = std_io_File_write_string(f, content);
    return __llpl_ret143;
}

Result_int_char_ptr* std_io_append_file(char* path, String* content) {
    std_io_File* f = std_io_File_new_char_ptr_int(path, ((std_io_O_WRONLY | std_io_O_CREAT) | std_io_O_APPEND));
    Result_int_char_ptr* result = Result_int_char_ptr_new();
    if (!std_io_File_is_valid(f)) {
        Result_int_char_ptr_set_err(result, "Cannot open file");
        Result_int_char_ptr* __llpl_ret144 = result;
        return __llpl_ret144;
    }
    Result_int_char_ptr* __llpl_ret145 = std_io_File_write_string(f, content);
    return __llpl_ret145;
}

int std_io_file_exists(char* path) {
    std_io_File* f = std_io_File_new_char_ptr_int(path, std_io_O_RDONLY);
    int __llpl_ret146 = std_io_File_is_valid(f);
    return __llpl_ret146;
}

int std_io_delete_file(char* path) {
    int __llpl_ret147 = (unlink(path) == 0);
    return __llpl_ret147;
}

int std_io_rename_file(char* oldpath, char* newpath) {
    int __llpl_ret148 = (rename(oldpath, newpath) == 0);
    return __llpl_ret148;
}

// Function bodies deferred until after plain class/struct definitions exist
uint64_t int_hash(int64_t self) {
    uint64_t __llpl_ret1 = ((uint64_t)self);
    return __llpl_ret1;
}
int int_equals(int64_t self, int64_t other) {
    int __llpl_ret2 = (self == other);
    return __llpl_ret2;
}
uint64_t uint_hash(uint64_t self) {
    uint64_t __llpl_ret3 = self;
    return __llpl_ret3;
}
int uint_equals(uint64_t self, uint64_t other) {
    int __llpl_ret4 = (self == other);
    return __llpl_ret4;
}
uint64_t char_hash(char self) {
    uint64_t __llpl_ret5 = ((uint64_t)self);
    return __llpl_ret5;
}
int char_equals(char self, char other) {
    int __llpl_ret6 = (self == other);
    return __llpl_ret6;
}
uint64_t char_ptr_hash(char* self) {
    uint64_t len = llpl_strlen(self);
    uint64_t h = 2166136261;
    uint64_t i = 0;
    while ((i < len)) {
        h = (h ^ ((uint64_t)self[i]));
        h = (h * 16777619);
        i = (i + 1);
    }
    uint64_t __llpl_ret7 = h;
    return __llpl_ret7;
}
int char_ptr_equals(char* self, char* other) {
    int __llpl_ret8 = (llpl_strcmp(self, other) == 0);
    return __llpl_ret8;
}
uint64_t String_hash(String* self) {
    uint64_t h = 2166136261;
    int64_t i = 0;
    while ((i < self->length)) {
        h = (h ^ ((uint64_t)self->buf[i]));
        h = (h * 16777619);
        i = (i + 1);
    }
    uint64_t __llpl_ret9 = h;
    return __llpl_ret9;
}
int String_equals(String* self, String* other) {
    if ((self->length != other->length)) {
        int __llpl_ret10 = 0;
        return __llpl_ret10;
    }
    int __llpl_ret11 = (llpl_strcmp(self->buf, other->buf) == 0);
    return __llpl_ret11;
}
int64_t int_compare(int64_t self, int64_t other) {
    if ((self < other)) {
        int64_t __llpl_ret12 = -1;
        return __llpl_ret12;
    }
    if ((self > other)) {
        int64_t __llpl_ret13 = 1;
        return __llpl_ret13;
    }
    int64_t __llpl_ret14 = 0;
    return __llpl_ret14;
}
int64_t uint_compare(uint64_t self, uint64_t other) {
    if ((self < other)) {
        int64_t __llpl_ret15 = -1;
        return __llpl_ret15;
    }
    if ((self > other)) {
        int64_t __llpl_ret16 = 1;
        return __llpl_ret16;
    }
    int64_t __llpl_ret17 = 0;
    return __llpl_ret17;
}
int64_t char_compare(char self, char other) {
    if ((self < other)) {
        int64_t __llpl_ret18 = -1;
        return __llpl_ret18;
    }
    if ((self > other)) {
        int64_t __llpl_ret19 = 1;
        return __llpl_ret19;
    }
    int64_t __llpl_ret20 = 0;
    return __llpl_ret20;
}
int char_ptr_op_eq(char* self, char* other) {
    int self_null = (((uint64_t)self) == 0);
    int other_null = (((uint64_t)other) == 0);
    if ((self_null || other_null)) {
        int __llpl_ret21 = (self_null && other_null);
        return __llpl_ret21;
    }
    int __llpl_ret22 = (llpl_strcmp(self, other) == 0);
    return __llpl_ret22;
}
int char_ptr_op_ne(char* self, char* other) {
    int __llpl_ret23 = !char_ptr_op_eq(self, other);
    return __llpl_ret23;
}
int char_ptr_op_lt(char* self, char* other) {
    int self_null = (((uint64_t)self) == 0);
    int other_null = (((uint64_t)other) == 0);
    if ((self_null || other_null)) {
        int __llpl_ret24 = (self_null && !other_null);
        return __llpl_ret24;
    }
    int __llpl_ret25 = (llpl_strcmp(self, other) < 0);
    return __llpl_ret25;
}
int char_ptr_op_gt(char* self, char* other) {
    int self_null = (((uint64_t)self) == 0);
    int other_null = (((uint64_t)other) == 0);
    if ((self_null || other_null)) {
        int __llpl_ret26 = (!self_null && other_null);
        return __llpl_ret26;
    }
    int __llpl_ret27 = (llpl_strcmp(self, other) > 0);
    return __llpl_ret27;
}
int char_ptr_op_le(char* self, char* other) {
    int __llpl_ret28 = !char_ptr_op_gt(self, other);
    return __llpl_ret28;
}
int char_ptr_op_ge(char* self, char* other) {
    int __llpl_ret29 = !char_ptr_op_lt(self, other);
    return __llpl_ret29;
}

// Symbol table for symbolized panic backtraces
LLPL_Symbol llpl_symbol_table[] = {
    { "std_io_file_exists", (void*)std_io_file_exists, "file.llpl", 227 },
    { "int_equals", (void*)int_equals, "?", 1233 },
    { "uint_hash", (void*)uint_hash, "?", 1239 },
    { "std_io_append_file", (void*)std_io_append_file, "file.llpl", 215 },
    { "char_ptr_op_ne", (void*)char_ptr_op_ne, "?", 1350 },
    { "char_equals", (void*)char_equals, "?", 1251 },
    { "char_ptr_op_lt", (void*)char_ptr_op_lt, "?", 1354 },
    { "char_ptr_equals", (void*)char_ptr_equals, "?", 1272 },
    { "char_ptr_hash", (void*)char_ptr_hash, "?", 1261 },
    { "std_io_write_file", (void*)std_io_write_file, "file.llpl", 203 },
    { "std_io_read_file", (void*)std_io_read_file, "file.llpl", 191 },
    { "char_ptr_op_ge", (void*)char_ptr_op_ge, "?", 1376 },
    { "int_hash", (void*)int_hash, "?", 1230 },
    { "char_ptr_op_gt", (void*)char_ptr_op_gt, "?", 1363 },
    { "char_hash", (void*)char_hash, "?", 1248 },
    { "uint_compare", (void*)uint_compare, "?", 1313 },
    { "char_ptr_op_eq", (void*)char_ptr_op_eq, "?", 1341 },
    { "std_io_rename_file", (void*)std_io_rename_file, "file.llpl", 236 },
    { "char_ptr_op_le", (void*)char_ptr_op_le, "?", 1372 },
    { "String_hash", (void*)String_hash, "?", 1280 },
    { "String_equals", (void*)String_equals, "?", 1290 },
    { "std_io_delete_file", (void*)std_io_delete_file, "file.llpl", 232 },
    { "uint_equals", (void*)uint_equals, "?", 1242 },
    { "char_compare", (void*)char_compare, "?", 1321 },
    { "int_compare", (void*)int_compare, "?", 1305 },
    { "reflect_type", (void*)reflect_type, "prelude.llpl", 154 },
    { "ReflectType_new", (void*)ReflectType_new, "prelude.llpl", 120 },
    { "ReflectType_exists", (void*)ReflectType_exists, "prelude.llpl", 126 },
    { "ReflectType_name", (void*)ReflectType_name, "prelude.llpl", 130 },
    { "ReflectType_kind", (void*)ReflectType_kind, "prelude.llpl", 134 },
    { "ReflectType_size", (void*)ReflectType_size, "prelude.llpl", 138 },
    { "ReflectType_field_count", (void*)ReflectType_field_count, "prelude.llpl", 142 },
    { "ReflectType_field", (void*)ReflectType_field, "prelude.llpl", 146 },
    { "RegexMatchIterator_new", (void*)RegexMatchIterator_new, "prelude.llpl", 306 },
    { "RegexMatchIterator_advance", (void*)RegexMatchIterator_advance, "prelude.llpl", 325 },
    { "RegexMatchIterator_iter_has_next", (void*)RegexMatchIterator_iter_has_next, "prelude.llpl", 346 },
    { "RegexMatchIterator_iter_next", (void*)RegexMatchIterator_iter_next, "prelude.llpl", 354 },
    { "Result_String_char_ptr_new", (void*)Result_String_char_ptr_new, "?", 1083 },
    { "Result_String_char_ptr_set_ok", (void*)Result_String_char_ptr_set_ok, "?", 1090 },
    { "Result_String_char_ptr_set_err", (void*)Result_String_char_ptr_set_err, "?", 1095 },
    { "Result_String_char_ptr_set_err_with_trace", (void*)Result_String_char_ptr_set_err_with_trace, "?", 1103 },
    { "Result_String_char_ptr_get_ok", (void*)Result_String_char_ptr_get_ok, "?", 1112 },
    { "Result_String_char_ptr_get_err", (void*)Result_String_char_ptr_get_err, "?", 1116 },
    { "Result_String_char_ptr_get_trace", (void*)Result_String_char_ptr_get_trace, "?", 1120 },
    { "Result_String_char_ptr_is_ok", (void*)Result_String_char_ptr_is_ok, "?", 1124 },
    { "Result_String_char_ptr_is_err", (void*)Result_String_char_ptr_is_err, "?", 1128 },
    { "String_new", (void*)String_new, "prelude.llpl", 459 },
    { "String_byte_len", (void*)String_byte_len, "prelude.llpl", 470 },
    { "String_len", (void*)String_len, "prelude.llpl", 474 },
    { "String_is_utf8", (void*)String_is_utf8, "prelude.llpl", 478 },
    { "String_byte_index", (void*)String_byte_index, "prelude.llpl", 482 },
    { "String_char_index", (void*)String_char_index, "prelude.llpl", 489 },
    { "String_codepoint_at", (void*)String_codepoint_at, "prelude.llpl", 496 },
    { "String_c_str", (void*)String_c_str, "prelude.llpl", 506 },
    { "String_byte_at", (void*)String_byte_at, "prelude.llpl", 510 },
    { "String_op_index", (void*)String_op_index, "prelude.llpl", 514 },
    { "String_iter_reset", (void*)String_iter_reset, "prelude.llpl", 522 },
    { "String_iter_has_next", (void*)String_iter_has_next, "prelude.llpl", 526 },
    { "String_iter_next", (void*)String_iter_next, "prelude.llpl", 530 },
    { "String_byte_set", (void*)String_byte_set, "prelude.llpl", 536 },
    { "String_op_eq", (void*)String_op_eq, "prelude.llpl", 540 },
    { "String_op_ne", (void*)String_op_ne, "prelude.llpl", 544 },
    { "String_op_lt", (void*)String_op_lt, "prelude.llpl", 548 },
    { "String_op_gt", (void*)String_op_gt, "prelude.llpl", 552 },
    { "String_op_add", (void*)String_op_add, "prelude.llpl", 562 },
    { "String_byte_substring", (void*)String_byte_substring, "prelude.llpl", 573 },
    { "String_substring", (void*)String_substring, "prelude.llpl", 594 },
    { "String_utf8_substring", (void*)String_utf8_substring, "prelude.llpl", 615 },
    { "String_byte_find", (void*)String_byte_find, "prelude.llpl", 620 },
    { "String_find", (void*)String_find, "prelude.llpl", 645 },
    { "String_contains", (void*)String_contains, "prelude.llpl", 653 },
    { "String_starts_with", (void*)String_starts_with, "prelude.llpl", 657 },
    { "String_ends_with", (void*)String_ends_with, "prelude.llpl", 672 },
    { "String_to_upper", (void*)String_to_upper, "prelude.llpl", 688 },
    { "String_to_lower", (void*)String_to_lower, "prelude.llpl", 704 },
    { "String_trim", (void*)String_trim, "prelude.llpl", 721 },
    { "Regex_new", (void*)Regex_new, "prelude.llpl", 366 },
    { "Regex_match", (void*)Regex_match, "prelude.llpl", 376 },
    { "Regex_captures", (void*)Regex_captures, "prelude.llpl", 380 },
    { "Regex_find_all", (void*)Regex_find_all, "prelude.llpl", 386 },
    { "Regex_replace", (void*)Regex_replace, "prelude.llpl", 393 },
    { "Regex_replace_all", (void*)Regex_replace_all, "prelude.llpl", 408 },
    { "Regex_source", (void*)Regex_source, "prelude.llpl", 429 },
    { "std_io_File_new_char_ptr_int", (void*)std_io_File_new_char_ptr_int, "file.llpl", 40 },
    { "std_io_File_new_char_ptr_int_int", (void*)std_io_File_new_char_ptr_int_int, "file.llpl", 46 },
    { "std_io_File_is_valid", (void*)std_io_File_is_valid, "file.llpl", 58 },
    { "std_io_File_read_bytes", (void*)std_io_File_read_bytes, "file.llpl", 62 },
    { "std_io_File_write_bytes", (void*)std_io_File_write_bytes, "file.llpl", 80 },
    { "std_io_File_read_string", (void*)std_io_File_read_string, "file.llpl", 98 },
    { "std_io_File_write_string", (void*)std_io_File_write_string, "file.llpl", 123 },
    { "std_io_File_seek", (void*)std_io_File_seek, "file.llpl", 127 },
    { "std_io_File_tell", (void*)std_io_File_tell, "file.llpl", 145 },
    { "std_io_File_size", (void*)std_io_File_size, "file.llpl", 149 },
    { "std_io_File_read_all", (void*)std_io_File_read_all, "file.llpl", 170 },
    { "std_io_File_flush", (void*)std_io_File_flush, "file.llpl", 184 },
    { "ReflectField_new", (void*)ReflectField_new, "prelude.llpl", 90 },
    { "ReflectField_exists", (void*)ReflectField_exists, "prelude.llpl", 96 },
    { "ReflectField_name", (void*)ReflectField_name, "prelude.llpl", 100 },
    { "ReflectField_type_name", (void*)ReflectField_type_name, "prelude.llpl", 104 },
    { "ReflectField_offset", (void*)ReflectField_offset, "prelude.llpl", 108 },
    { "ReflectField_size", (void*)ReflectField_size, "prelude.llpl", 112 },
    { "Result_int_char_ptr_new", (void*)Result_int_char_ptr_new, "?", 1083 },
    { "Result_int_char_ptr_set_ok", (void*)Result_int_char_ptr_set_ok, "?", 1090 },
    { "Result_int_char_ptr_set_err", (void*)Result_int_char_ptr_set_err, "?", 1095 },
    { "Result_int_char_ptr_set_err_with_trace", (void*)Result_int_char_ptr_set_err_with_trace, "?", 1103 },
    { "Result_int_char_ptr_get_ok", (void*)Result_int_char_ptr_get_ok, "?", 1112 },
    { "Result_int_char_ptr_get_err", (void*)Result_int_char_ptr_get_err, "?", 1116 },
    { "Result_int_char_ptr_get_trace", (void*)Result_int_char_ptr_get_trace, "?", 1120 },
    { "Result_int_char_ptr_is_ok", (void*)Result_int_char_ptr_is_ok, "?", 1124 },
    { "Result_int_char_ptr_is_err", (void*)Result_int_char_ptr_is_err, "?", 1128 },
    { "RegexMatch_new", (void*)RegexMatch_new, "prelude.llpl", 170 },
    { "RegexMatch_is_match", (void*)RegexMatch_is_match, "prelude.llpl", 188 },
    { "RegexMatch_group_count", (void*)RegexMatch_group_count, "prelude.llpl", 192 },
    { "RegexMatch_has_group", (void*)RegexMatch_has_group, "prelude.llpl", 196 },
    { "RegexMatch_group_start", (void*)RegexMatch_group_start, "prelude.llpl", 205 },
    { "RegexMatch_group_end", (void*)RegexMatch_group_end, "prelude.llpl", 217 },
    { "RegexMatch_group", (void*)RegexMatch_group, "prelude.llpl", 229 },
    { "RegexMatch_expand", (void*)RegexMatch_expand, "prelude.llpl", 244 },
    { "OwnedBuffer_new", (void*)OwnedBuffer_new, "prelude.llpl", 777 },
    { "OwnedBuffer_free", (void*)OwnedBuffer_free, "prelude.llpl", 786 },
    { "OwnedBuffer_data", (void*)OwnedBuffer_data, "prelude.llpl", 794 },
    { "OwnedBuffer_len", (void*)OwnedBuffer_len, "prelude.llpl", 798 },
    { "OwnedBuffer_is_null", (void*)OwnedBuffer_is_null, "prelude.llpl", 802 },
    { "OwnedBuffer_byte_at", (void*)OwnedBuffer_byte_at, "prelude.llpl", 806 },
    { "OwnedBuffer_set", (void*)OwnedBuffer_set, "prelude.llpl", 813 },
    { "OwnedBuffer_as_slice", (void*)OwnedBuffer_as_slice, "prelude.llpl", 820 },
    { "OwnedBuffer_take", (void*)OwnedBuffer_take, "prelude.llpl", 827 },
};
uint64_t llpl_symbol_table_count = 127;


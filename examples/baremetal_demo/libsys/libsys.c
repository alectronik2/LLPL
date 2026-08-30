#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include "runtime.h"

// Monomorphized generic instantiations - forward declarations
uint64_t int_hash(int64_t self);
bool int_equals(int64_t self, int64_t other);
uint64_t uint_hash(uint64_t self);
bool uint_equals(uint64_t self, uint64_t other);
uint64_t char_hash(char self);
bool char_equals(char self, char other);
uint64_t char_ptr_hash(char* self);
bool char_ptr_equals(char* self, char* other);
typedef struct String String;
uint64_t String_hash(String* self);
typedef struct String String;
bool String_equals(String* self, String* other);
int64_t int_compare(int64_t self, int64_t other);
int64_t uint_compare(uint64_t self, uint64_t other);
int64_t char_compare(char self, char other);
bool char_ptr_op_eq(char* self, char* other);
bool char_ptr_op_ne(char* self, char* other);
bool char_ptr_op_lt(char* self, char* other);
bool char_ptr_op_gt(char* self, char* other);
bool char_ptr_op_le(char* self, char* other);
bool char_ptr_op_ge(char* self, char* other);
typedef struct Vector_ParseNode Vector_ParseNode;
typedef struct ParseNode ParseNode;
Vector_ParseNode* Vector_ParseNode_new();
void Vector_ParseNode_destroy(void* ptr);
void Vector_ParseNode_push(Vector_ParseNode* self, ParseNode* item);
void Vector_ParseNode_grow(Vector_ParseNode* self);
ParseNode* Vector_ParseNode_get(Vector_ParseNode* self, int64_t index);
void Vector_ParseNode_set(Vector_ParseNode* self, int64_t index, ParseNode* item);
ParseNode* Vector_ParseNode_pop(Vector_ParseNode* self);
int64_t Vector_ParseNode_len(Vector_ParseNode* self);
bool Vector_ParseNode_is_empty(Vector_ParseNode* self);
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
typedef struct AllocHeader AllocHeader;
typedef struct AllocState AllocState;

extern int64_t ksnprintf(char* buf, uint64_t size, char* fmt, ...);
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
uint64_t syscall0(uint64_t number);
uint64_t syscall1(uint64_t number, uint64_t a);
uint64_t syscall2(uint64_t number, uint64_t a, uint64_t b);
uint64_t syscall3(uint64_t number, uint64_t a, uint64_t b, uint64_t c);
uint64_t sys_exit(uint64_t code);
uint64_t sys_pri64(uint8_t* buf, uint64_t len);
uint64_t sys_mmap(uint64_t virt_hi64, uint64_t pages, uint64_t flags);
uint64_t sys_munmap(uint64_t addr, uint64_t pages);
uint64_t sys_getpid();
uint64_t sys_yield();
uint64_t sys_sleep(uint64_t ticks);
uint64_t sys_open(uint8_t* path, uint64_t mode);
uint64_t sys_read(uint64_t fd, uint8_t* buf, uint64_t len);
uint64_t sys_write(uint64_t fd, uint8_t* buf, uint64_t len);
uint64_t sys_close(uint64_t fd);
uint64_t sys_msg_send(uint64_t handle, uint8_t* buf, uint64_t len);
uint64_t sys_msg_recv(uint8_t* buf, uint64_t len);
uint64_t sys_msg_try_recv(uint8_t* buf, uint64_t len);
uint64_t sys_readdir(uint8_t* path, uint64_t index, uint8_t* out_buf);
uint64_t sys_focus_state();
uint64_t sys_msg_reply(uint64_t peer, uint8_t* buf, uint64_t len);
uint64_t sys_spawn(uint8_t* path, uint8_t* args);
uint64_t sys_exec(uint8_t* path, uint8_t* args);
uint64_t sys_wait(uint64_t handle);
uint64_t sys_kill(uint64_t handle);
uint64_t sys_register(uint8_t* name);
uint64_t sys_lookup(uint8_t* name);
uint8_t* sys_shm_create(uint64_t pages);
uint8_t* sys_shm_map(uint64_t handle);
uint64_t sys_inb(uint64_t port);
uint64_t sys_outb(uint64_t port, uint64_t value);
uint64_t sys_inw(uint64_t port);
uint64_t sys_outw(uint64_t port, uint64_t value);
uint64_t sys_inl(uint64_t port);
uint64_t sys_outl(uint64_t port, uint64_t value);
uint64_t sys_bmide_base();
uint64_t sys_virt_to_phys(uint64_t virt);
uint8_t* sys_nic_mmap();
uint64_t sys_fb_info(uint64_t* out);
uint8_t* sys_fb_map();
uint64_t sys_kbd_poll();
uint64_t sys_mouse_poll();
uint64_t sys_strlen(uint8_t* s);
uint64_t sys_puts(uint8_t* s);
uint64_t sys_putln(uint8_t* s);
uint8_t* sys_memset(uint8_t* dst, uint8_t value, uint64_t len);
uint8_t* sys_memcpy(uint8_t* dst, uint8_t* src, uint64_t len);
int64_t sys_strcmp(uint8_t* a, uint8_t* b);
bool sys_streq(uint8_t* a, uint8_t* b);
uint8_t* sys_strcpy(uint8_t* dst, uint8_t* src);
uint64_t sys_read_all(uint8_t* path, uint8_t* buf, uint64_t len);
uint64_t sys_write_all(uint8_t* path, uint8_t* buf, uint64_t len);
uint8_t* sys_alloc_pages(uint64_t pages);
uint64_t align16(uint64_t n);
uint64_t pages_for_bytes(uint64_t n);
AllocState* alloc_state();
uint8_t* alloc_large(uint64_t size, uint64_t total);
uint8_t* alloc_small(uint64_t size, uint64_t total);
uint8_t* sys_malloc(uint64_t size);
uint64_t sys_free(uint8_t* ptr);

extern const int64_t SYS_EXIT;
extern const int64_t SYS_PRi64;
extern const int64_t SYS_MMAP;
extern const int64_t SYS_GETPID;
extern const int64_t SYS_YIELD;
extern const int64_t SYS_SLEEP;
extern const int64_t SYS_OPEN;
extern const int64_t SYS_READ;
extern const int64_t SYS_WRITE;
extern const int64_t SYS_CLOSE;
extern const int64_t SYS_MSG_SEND;
extern const int64_t SYS_MSG_RECV;
extern const int64_t SYS_MSG_REPLY;
extern const int64_t SYS_SPAWN;
extern const int64_t SYS_EXEC;
extern const int64_t SYS_WAIT;
extern const int64_t SYS_KILL;
extern const int64_t SYS_MUNMAP;
extern const int64_t SYS_REGISTER;
extern const int64_t SYS_LOOKUP;
extern const int64_t SYS_SHM_CREATE;
extern const int64_t SYS_SHM_MAP;
extern const int64_t SYS_INB;
extern const int64_t SYS_OUTB;
extern const int64_t SYS_INW;
extern const int64_t SYS_OUTW;
extern const int64_t SYS_FB_INFO;
extern const int64_t SYS_FB_MAP;
extern const int64_t SYS_KBD_POLL;
extern const int64_t SYS_MOUSE_POLL;
extern const int64_t SYS_MSG_TRY_RECV;
extern const int64_t SYS_READDIR;
extern const int64_t SYS_FOCUS_STATE;
extern const int64_t SYS_INL;
extern const int64_t SYS_OUTL;
extern const int64_t SYS_BMIDE_BASE;
extern const int64_t SYS_VIRT_TO_PHYS;
extern const int64_t SYS_NIC_MMAP;
extern const int64_t SYS_ERR;
extern const int64_t O_RDONLY;
extern const int64_t O_CREATE;
extern const int64_t KEY_UP;
extern const int64_t KEY_DOWN;
extern const int64_t KEY_LEFT;
extern const int64_t KEY_RIGHT;
extern const int64_t ALLOC_MAGIC;
extern const int64_t ALLOC_FREED;
extern const int64_t ALLOC_FLAG_LARGE;
extern const int64_t PAGE_SIZE;
extern const int64_t LARGE_ALLOC_MIN;
extern const int64_t USER_PTR_MIN;
extern const int64_t ALLOC_STATE_ADDR;
extern const int64_t ALLOC_STATE_MAGIC;


struct EmbeddedFile {
    char* data;
    uint64_t len;
};

struct __attribute__((packed)) AllocHeader {
    uint64_t magic;
    uint64_t size;
    uint64_t pages;
    uint64_t base;
    uint64_t flags;
    uint64_t reserved;
};

struct __attribute__((packed)) AllocState {
    uint64_t heap_cur;
    uint64_t heap_end;
    uint64_t free_small;
    uint64_t initialized;
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
    int64_t new_capacity = (self->capacity * 2);
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
    ParseNode* __llpl_ret31 = self->data[self->length];
    return __llpl_ret31;
}

int64_t Vector_ParseNode_len(Vector_ParseNode* self) {
    int64_t __llpl_ret32 = self->length;
    return __llpl_ret32;
}

bool Vector_ParseNode_is_empty(Vector_ParseNode* self) {
    bool __llpl_ret33 = (self->length == 0);
    return __llpl_ret33;
}

Slice_ParseNode Vector_ParseNode_as_slice(Vector_ParseNode* self) {
    Slice_ParseNode __llpl_ret34 = (Slice_ParseNode){ .ptr = self->data, .len = ((uint64_t)self->length) };
    return __llpl_ret34;
}


// Module: /home/nix/Claude/LLPL/prelude.llpl (structs)

// Module: /home/nix/Claude/LLPL/examples/baremetal_demo/libsys/libsys.llpl (structs)


// Module: /home/nix/Claude/LLPL/prelude.llpl
extern int64_t ksnprintf(char* buf, uint64_t size, char* fmt, ...);

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

extern void llpl_panic(char* msg);

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
    bool __llpl_ret35 = (((uint64_t)self->raw) != 0);
    return __llpl_ret35;
}

char* ReflectField_name(ReflectField* self) {
    char* __llpl_ret36 = llpl_reflect_field_name(self->raw);
    return __llpl_ret36;
}

char* ReflectField_type_name(ReflectField* self) {
    char* __llpl_ret37 = llpl_reflect_field_type_name(self->raw);
    return __llpl_ret37;
}

int64_t ReflectField_offset(ReflectField* self) {
    int64_t __llpl_ret38 = ((int64_t)llpl_reflect_field_offset(self->raw));
    return __llpl_ret38;
}

int64_t ReflectField_size(ReflectField* self) {
    int64_t __llpl_ret39 = ((int64_t)llpl_reflect_field_size(self->raw));
    return __llpl_ret39;
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
    bool __llpl_ret40 = (((uint64_t)self->raw) != 0);
    return __llpl_ret40;
}

char* ReflectType_name(ReflectType* self) {
    char* __llpl_ret41 = llpl_reflect_type_name(self->raw);
    return __llpl_ret41;
}

char* ReflectType_kind(ReflectType* self) {
    char* __llpl_ret42 = llpl_reflect_type_kind(self->raw);
    return __llpl_ret42;
}

int64_t ReflectType_size(ReflectType* self) {
    int64_t __llpl_ret43 = ((int64_t)llpl_reflect_type_size(self->raw));
    return __llpl_ret43;
}

int64_t ReflectType_field_count(ReflectType* self) {
    int64_t __llpl_ret44 = ((int64_t)llpl_reflect_field_count(self->raw));
    return __llpl_ret44;
}

ReflectField* ReflectType_field(ReflectType* self, int64_t index) {
    if ((index < 0)) {
        ReflectField* __llpl_ret45 = ReflectField_new(NULL);
        return __llpl_ret45;
    }
    ReflectField* __llpl_ret46 = ReflectField_new(llpl_reflect_field(self->raw, ((uint64_t)index)));
    return __llpl_ret46;
}



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

bool RegexMatch_is_match(RegexMatch* self) {
    bool __llpl_ret47 = self->matched;
    return __llpl_ret47;
}

int64_t RegexMatch_group_count(RegexMatch* self) {
    int64_t __llpl_ret48 = ((int64_t)llpl_regex_group_count(self->pattern));
    return __llpl_ret48;
}

bool RegexMatch_has_group(RegexMatch* self, int64_t index) {
    if ((index < 0)) {
        bool __llpl_ret49 = 0;
        return __llpl_ret49;
    }
    int64_t start = 0;
    int64_t end = 0;
    bool __llpl_ret50 = llpl_regex_capture_bounds(self->pattern, self->text, ((uint64_t)index), &start, &end);
    return __llpl_ret50;
}

int64_t RegexMatch_group_start(RegexMatch* self, int64_t index) {
    if ((index < 0)) {
        int64_t __llpl_ret51 = -1;
        return __llpl_ret51;
    }
    int64_t start = 0;
    int64_t end = 0;
    if (llpl_regex_capture_bounds(self->pattern, self->text, ((uint64_t)index), &start, &end)) {
        int64_t __llpl_ret52 = (start + self->base_offset);
        return __llpl_ret52;
    }
    int64_t __llpl_ret53 = -1;
    return __llpl_ret53;
}

int64_t RegexMatch_group_end(RegexMatch* self, int64_t index) {
    if ((index < 0)) {
        int64_t __llpl_ret54 = -1;
        return __llpl_ret54;
    }
    int64_t start = 0;
    int64_t end = 0;
    if (llpl_regex_capture_bounds(self->pattern, self->text, ((uint64_t)index), &start, &end)) {
        int64_t __llpl_ret55 = (end + self->base_offset);
        return __llpl_ret55;
    }
    int64_t __llpl_ret56 = -1;
    return __llpl_ret56;
}

String* RegexMatch_group(RegexMatch* self, int64_t index) {
    if ((index < 0)) {
        String* __llpl_ret57 = String_new("");
        return __llpl_ret57;
    }
    char* raw = llpl_regex_capture(self->pattern, self->text, ((uint64_t)index));
    String* out = String_new(raw);
    llpl_free(raw);
    String* __llpl_ret58 = out;
    return __llpl_ret58;
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
    String* __llpl_ret59 = result;
    return __llpl_ret59;
}


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

bool RegexMatchIterator_advance(RegexMatchIterator* self) {
    if ((self->done || (self->pos > self->text_len))) {
        self->done = 1;
        bool __llpl_ret60 = 0;
        return __llpl_ret60;
    }
    RegexMatch* m = RegexMatch_new(self->pattern, (self->text + self->pos), self->pos);
    if (!RegexMatch_is_match(m)) {
        self->done = 1;
        bool __llpl_ret61 = 0;
        return __llpl_ret61;
    }
    self->current = m;
    int64_t end_in_suffix = (RegexMatch_group_end(m, 0) - self->pos);
    int64_t start_in_suffix = (RegexMatch_group_start(m, 0) - self->pos);
    if ((end_in_suffix == start_in_suffix)) {
        self->pos = ((self->pos + end_in_suffix) + 1);
    } else {
        self->pos = (self->pos + end_in_suffix);
    }
    bool __llpl_ret62 = 1;
    return __llpl_ret62;
}

bool RegexMatchIterator_iter_has_next(RegexMatchIterator* self) {
    if (self->has_current) {
        bool __llpl_ret63 = 1;
        return __llpl_ret63;
    }
    self->has_current = RegexMatchIterator_advance(self);
    bool __llpl_ret64 = self->has_current;
    return __llpl_ret64;
}

RegexMatch* RegexMatchIterator_iter_next(RegexMatchIterator* self) {
    if (!self->has_current) {
        RegexMatchIterator_advance(self);
    }
    self->has_current = 0;
    RegexMatch* __llpl_ret65 = self->current;
    return __llpl_ret65;
}


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

bool Regex_match(Regex* self, char* text) {
    bool __llpl_ret66 = llpl_regex_match(self->pattern, text);
    return __llpl_ret66;
}

RegexMatch* Regex_captures(Regex* self, char* text) {
    RegexMatch* __llpl_ret67 = RegexMatch_new(self->pattern, text, 0);
    return __llpl_ret67;
}

RegexMatchIterator* Regex_find_all(Regex* self, char* text) {
    RegexMatchIterator* __llpl_ret68 = RegexMatchIterator_new(self->pattern, text);
    return __llpl_ret68;
}

String* Regex_replace(Regex* self, char* text, char* replacement) {
    RegexMatch* m = Regex_captures(self, text);
    if (!RegexMatch_is_match(m)) {
        String* __llpl_ret69 = String_new(text);
        return __llpl_ret69;
    }
    String* ts = String_new(text);
    int64_t start = RegexMatch_group_start(m, 0);
    int64_t end = RegexMatch_group_end(m, 0);
    String* result = String_byte_substring(ts, 0, start);
    result = String_op_add(result, String_c_str(RegexMatch_expand(m, replacement)));
    result = String_op_add(result, String_c_str(String_byte_substring(ts, end, (String_byte_len(ts) - end))));
    String* __llpl_ret70 = result;
    return __llpl_ret70;
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
    String* __llpl_ret71 = result;
    return __llpl_ret71;
}

char* Regex_source(Regex* self) {
    char* __llpl_ret72 = self->pattern;
    return __llpl_ret72;
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
    int64_t __llpl_ret73 = self->length;
    return __llpl_ret73;
}

int64_t String_len(String* self) {
    int64_t __llpl_ret74 = ((int64_t)llpl_utf8_len(self->buf));
    return __llpl_ret74;
}

bool String_is_utf8(String* self) {
    bool __llpl_ret75 = llpl_utf8_valid(self->buf);
    return __llpl_ret75;
}

int64_t String_byte_index(String* self, int64_t char_index) {
    if ((char_index < 0)) {
        int64_t __llpl_ret76 = 0;
        return __llpl_ret76;
    }
    int64_t __llpl_ret77 = ((int64_t)llpl_utf8_byte_offset(self->buf, ((uint64_t)char_index)));
    return __llpl_ret77;
}

int64_t String_char_index(String* self, int64_t byte_offset) {
    if ((byte_offset < 0)) {
        int64_t __llpl_ret78 = 0;
        return __llpl_ret78;
    }
    int64_t __llpl_ret79 = ((int64_t)llpl_utf8_char_index(self->buf, ((uint64_t)byte_offset)));
    return __llpl_ret79;
}

uint64_t String_codepoint_at(String* self, int64_t char_index) {
    if ((char_index < 0)) {
        uint64_t __llpl_ret80 = 0;
        return __llpl_ret80;
    }
    uint64_t __llpl_ret81 = llpl_utf8_codepoint_at(self->buf, ((uint64_t)char_index));
    return __llpl_ret81;
}

char* String_c_str(String* self) {
    char* __llpl_ret82 = self->buf;
    return __llpl_ret82;
}

char String_byte_at(String* self, int64_t index) {
    char __llpl_ret83 = self->buf[index];
    return __llpl_ret83;
}

uint64_t String_op_index(String* self, int64_t index) {
    uint64_t __llpl_ret84 = String_codepoint_at(self, index);
    return __llpl_ret84;
}

void String_iter_reset(String* self) {
    self->iter_pos = 0;
}

bool String_iter_has_next(String* self) {
    bool __llpl_ret85 = (self->iter_pos < String_len(self));
    return __llpl_ret85;
}

uint64_t String_iter_next(String* self) {
    uint64_t c = String_codepoint_at(self, self->iter_pos);
    self->iter_pos = (self->iter_pos + 1);
    uint64_t __llpl_ret86 = c;
    return __llpl_ret86;
}

void String_byte_set(String* self, int64_t index, char value) {
    self->buf[index] = value;
}

bool String_op_eq_char_ptr(String* self, char* other) {
    bool __llpl_ret87 = (llpl_strcmp(self->buf, other) == 0);
    return __llpl_ret87;
}

bool String_op_ne_char_ptr(String* self, char* other) {
    bool __llpl_ret88 = !String_op_eq_char_ptr(self, other);
    return __llpl_ret88;
}

bool String_op_lt_char_ptr(String* self, char* other) {
    bool __llpl_ret89 = (llpl_strcmp(self->buf, other) < 0);
    return __llpl_ret89;
}

bool String_op_gt_char_ptr(String* self, char* other) {
    bool __llpl_ret90 = (llpl_strcmp(self->buf, other) > 0);
    return __llpl_ret90;
}

bool String_op_eq_String(String* self, String* other) {
    bool __llpl_ret91 = String_op_eq_char_ptr(self, String_c_str(other));
    return __llpl_ret91;
}

bool String_op_ne_String(String* self, String* other) {
    bool __llpl_ret92 = String_op_ne_char_ptr(self, String_c_str(other));
    return __llpl_ret92;
}

bool String_op_lt_String(String* self, String* other) {
    bool __llpl_ret93 = String_op_lt_char_ptr(self, String_c_str(other));
    return __llpl_ret93;
}

bool String_op_gt_String(String* self, String* other) {
    bool __llpl_ret94 = String_op_gt_char_ptr(self, String_c_str(other));
    return __llpl_ret94;
}

String* String_op_add(String* self, char* other) {
    int64_t other_len = ((int64_t)llpl_strlen(other));
    int64_t total = (self->length + other_len);
    char* joined = llpl_alloc(((uint64_t)(total + 1)));
    llpl_memcpy(joined, self->buf, ((uint64_t)self->length));
    llpl_memcpy((joined + self->length), other, ((uint64_t)(other_len + 1)));
    String* __llpl_ret95 = String_new(joined);
    return __llpl_ret95;
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
    String* __llpl_ret96 = String_new(piece);
    return __llpl_ret96;
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
    String* __llpl_ret97 = String_byte_substring(self, byte_start, (byte_end - byte_start));
    return __llpl_ret97;
}

String* String_utf8_substring(String* self, int64_t start, int64_t count) {
    String* __llpl_ret98 = String_substring(self, start, count);
    return __llpl_ret98;
}

int64_t String_byte_find(String* self, char* needle) {
    int64_t needle_len = ((int64_t)llpl_strlen(needle));
    if ((needle_len == 0)) {
        int64_t __llpl_ret99 = 0;
        return __llpl_ret99;
    }
    int64_t i = 0;
    while ((i <= (self->length - needle_len))) {
        int64_t j = 0;
        bool matched = 1;
        while (((j < needle_len) && matched)) {
            if ((self->buf[(i + j)] != needle[j])) {
                matched = 0;
            }
            j = (j + 1);
        }
        if (matched) {
            int64_t __llpl_ret100 = i;
            return __llpl_ret100;
        }
        i = (i + 1);
    }
    int64_t __llpl_ret101 = -1;
    return __llpl_ret101;
}

int64_t String_find(String* self, char* needle) {
    int64_t byte_pos = String_byte_find(self, needle);
    if ((byte_pos < 0)) {
        int64_t __llpl_ret102 = -1;
        return __llpl_ret102;
    }
    int64_t __llpl_ret103 = String_char_index(self, byte_pos);
    return __llpl_ret103;
}

bool String_contains(String* self, char* needle) {
    bool __llpl_ret104 = (String_find(self, needle) >= 0);
    return __llpl_ret104;
}

bool String_starts_with(String* self, char* prefix) {
    int64_t prefix_len = ((int64_t)llpl_strlen(prefix));
    if ((prefix_len > self->length)) {
        bool __llpl_ret105 = 0;
        return __llpl_ret105;
    }
    int64_t i = 0;
    while ((i < prefix_len)) {
        if ((self->buf[i] != prefix[i])) {
            bool __llpl_ret106 = 0;
            return __llpl_ret106;
        }
        i = (i + 1);
    }
    bool __llpl_ret107 = 1;
    return __llpl_ret107;
}

bool String_ends_with(String* self, char* suffix) {
    int64_t suffix_len = ((int64_t)llpl_strlen(suffix));
    if ((suffix_len > self->length)) {
        bool __llpl_ret108 = 0;
        return __llpl_ret108;
    }
    int64_t offset = (self->length - suffix_len);
    int64_t i = 0;
    while ((i < suffix_len)) {
        if ((self->buf[(offset + i)] != suffix[i])) {
            bool __llpl_ret109 = 0;
            return __llpl_ret109;
        }
        i = (i + 1);
    }
    bool __llpl_ret110 = 1;
    return __llpl_ret110;
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
    String* __llpl_ret111 = String_new(out);
    return __llpl_ret111;
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
    String* __llpl_ret112 = String_new(out);
    return __llpl_ret112;
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
    String* __llpl_ret113 = String_byte_substring(self, start, (end - start));
    return __llpl_ret113;
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
        self->length = 0;
    }
}

char* OwnedBuffer_data(OwnedBuffer* self) {
    char* __llpl_ret114 = self->ptr;
    return __llpl_ret114;
}

uint64_t OwnedBuffer_len(OwnedBuffer* self) {
    uint64_t __llpl_ret115 = self->length;
    return __llpl_ret115;
}

bool OwnedBuffer_is_null(OwnedBuffer* self) {
    bool __llpl_ret116 = (self->ptr == NULL);
    return __llpl_ret116;
}

char OwnedBuffer_byte_at(OwnedBuffer* self, uint64_t index) {
    if ((index >= self->length)) {
        llpl_panic("OwnedBuffer.byte_at: index out of bounds");
    }
    char __llpl_ret117 = self->ptr[((int64_t)index)];
    return __llpl_ret117;
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
    Slice_char __llpl_ret118 = s;
    return __llpl_ret118;
}

char* OwnedBuffer_take(OwnedBuffer* self) {
    char* out = self->ptr;
    self->ptr = NULL;
    self->length = 0;
    char* __llpl_ret119 = out;
    return __llpl_ret119;
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
    String* __llpl_ret120 = self->rule_name;
    return __llpl_ret120;
}

String* ParseNode_text(ParseNode* self) {
    String* __llpl_ret121 = self->text_val;
    return __llpl_ret121;
}

ParseNode* ParseNode_child(ParseNode* self, int64_t index) {
    ParseNode* __llpl_ret122 = Vector_ParseNode_get(self->children, index);
    return __llpl_ret122;
}

int64_t ParseNode_child_count(ParseNode* self) {
    int64_t __llpl_ret123 = Vector_ParseNode_len(self->children);
    return __llpl_ret123;
}


// Module: /home/nix/Claude/LLPL/examples/baremetal_demo/libsys/libsys.llpl
const int64_t SYS_EXIT = 0;

const int64_t SYS_PRi64 = 1;

const int64_t SYS_MMAP = 2;

const int64_t SYS_GETPID = 3;

const int64_t SYS_YIELD = 4;

const int64_t SYS_SLEEP = 5;

const int64_t SYS_OPEN = 6;

const int64_t SYS_READ = 7;

const int64_t SYS_WRITE = 8;

const int64_t SYS_CLOSE = 9;

const int64_t SYS_MSG_SEND = 10;

const int64_t SYS_MSG_RECV = 11;

const int64_t SYS_MSG_REPLY = 12;

const int64_t SYS_SPAWN = 13;

const int64_t SYS_EXEC = 14;

const int64_t SYS_WAIT = 15;

const int64_t SYS_KILL = 16;

const int64_t SYS_MUNMAP = 17;

const int64_t SYS_REGISTER = 18;

const int64_t SYS_LOOKUP = 19;

const int64_t SYS_SHM_CREATE = 20;

const int64_t SYS_SHM_MAP = 21;

const int64_t SYS_INB = 22;

const int64_t SYS_OUTB = 23;

const int64_t SYS_INW = 24;

const int64_t SYS_OUTW = 25;

const int64_t SYS_FB_INFO = 26;

const int64_t SYS_FB_MAP = 27;

const int64_t SYS_KBD_POLL = 28;

const int64_t SYS_MOUSE_POLL = 29;

const int64_t SYS_MSG_TRY_RECV = 30;

const int64_t SYS_READDIR = 31;

const int64_t SYS_FOCUS_STATE = 32;

const int64_t SYS_INL = 33;

const int64_t SYS_OUTL = 34;

const int64_t SYS_BMIDE_BASE = 35;

const int64_t SYS_VIRT_TO_PHYS = 36;

const int64_t SYS_NIC_MMAP = 37;

const int64_t SYS_ERR = -1;

const int64_t O_RDONLY = 0;

const int64_t O_CREATE = 1;

uint64_t syscall0(uint64_t number) {
    uint64_t ret = 0;
    __asm__ __volatile__ (
        "int $0x80\n\t"
        : "=a"(ret)
        : "a"(number)
        : "memory"
    );
    uint64_t __llpl_ret124 = ret;
    return __llpl_ret124;
}

uint64_t syscall1(uint64_t number, uint64_t a) {
    uint64_t ret = 0;
    __asm__ __volatile__ (
        "int $0x80\n\t"
        : "=a"(ret)
        : "a"(number), "D"(a)
        : "memory"
    );
    uint64_t __llpl_ret125 = ret;
    return __llpl_ret125;
}

uint64_t syscall2(uint64_t number, uint64_t a, uint64_t b) {
    uint64_t ret = 0;
    __asm__ __volatile__ (
        "int $0x80\n\t"
        : "=a"(ret)
        : "a"(number), "D"(a), "S"(b)
        : "memory"
    );
    uint64_t __llpl_ret126 = ret;
    return __llpl_ret126;
}

uint64_t syscall3(uint64_t number, uint64_t a, uint64_t b, uint64_t c) {
    uint64_t ret = 0;
    __asm__ __volatile__ (
        "int $0x80\n\t"
        : "=a"(ret)
        : "a"(number), "D"(a), "S"(b), "d"(c)
        : "memory"
    );
    uint64_t __llpl_ret127 = ret;
    return __llpl_ret127;
}

uint64_t sys_exit(uint64_t code) {
    uint64_t __llpl_ret128 = syscall1(SYS_EXIT, code);
    return __llpl_ret128;
}

uint64_t sys_pri64(uint8_t* buf, uint64_t len) {
    uint64_t __llpl_ret129 = syscall2(SYS_PRi64, ((uint64_t)buf), len);
    return __llpl_ret129;
}

uint64_t sys_mmap(uint64_t virt_hi64, uint64_t pages, uint64_t flags) {
    uint64_t __llpl_ret130 = syscall3(SYS_MMAP, virt_hi64, pages, flags);
    return __llpl_ret130;
}

uint64_t sys_munmap(uint64_t addr, uint64_t pages) {
    uint64_t __llpl_ret131 = syscall2(SYS_MUNMAP, addr, pages);
    return __llpl_ret131;
}

uint64_t sys_getpid() {
    uint64_t __llpl_ret132 = syscall0(SYS_GETPID);
    return __llpl_ret132;
}

uint64_t sys_yield() {
    uint64_t __llpl_ret133 = syscall0(SYS_YIELD);
    return __llpl_ret133;
}

uint64_t sys_sleep(uint64_t ticks) {
    uint64_t __llpl_ret134 = syscall1(SYS_SLEEP, ticks);
    return __llpl_ret134;
}

uint64_t sys_open(uint8_t* path, uint64_t mode) {
    uint64_t __llpl_ret135 = syscall2(SYS_OPEN, ((uint64_t)path), mode);
    return __llpl_ret135;
}

uint64_t sys_read(uint64_t fd, uint8_t* buf, uint64_t len) {
    uint64_t __llpl_ret136 = syscall3(SYS_READ, fd, ((uint64_t)buf), len);
    return __llpl_ret136;
}

uint64_t sys_write(uint64_t fd, uint8_t* buf, uint64_t len) {
    uint64_t __llpl_ret137 = syscall3(SYS_WRITE, fd, ((uint64_t)buf), len);
    return __llpl_ret137;
}

uint64_t sys_close(uint64_t fd) {
    uint64_t __llpl_ret138 = syscall1(SYS_CLOSE, fd);
    return __llpl_ret138;
}

uint64_t sys_msg_send(uint64_t handle, uint8_t* buf, uint64_t len) {
    uint64_t __llpl_ret139 = syscall3(SYS_MSG_SEND, handle, ((uint64_t)buf), len);
    return __llpl_ret139;
}

uint64_t sys_msg_recv(uint8_t* buf, uint64_t len) {
    uint64_t __llpl_ret140 = syscall2(SYS_MSG_RECV, ((uint64_t)buf), len);
    return __llpl_ret140;
}

uint64_t sys_msg_try_recv(uint8_t* buf, uint64_t len) {
    uint64_t __llpl_ret141 = syscall2(SYS_MSG_TRY_RECV, ((uint64_t)buf), len);
    return __llpl_ret141;
}

uint64_t sys_readdir(uint8_t* path, uint64_t index, uint8_t* out_buf) {
    uint64_t __llpl_ret142 = syscall3(SYS_READDIR, ((uint64_t)path), index, ((uint64_t)out_buf));
    return __llpl_ret142;
}

uint64_t sys_focus_state() {
    uint64_t __llpl_ret143 = syscall0(SYS_FOCUS_STATE);
    return __llpl_ret143;
}

uint64_t sys_msg_reply(uint64_t peer, uint8_t* buf, uint64_t len) {
    uint64_t __llpl_ret144 = syscall3(SYS_MSG_REPLY, peer, ((uint64_t)buf), len);
    return __llpl_ret144;
}

uint64_t sys_spawn(uint8_t* path, uint8_t* args) {
    uint64_t __llpl_ret145 = syscall2(SYS_SPAWN, ((uint64_t)path), ((uint64_t)args));
    return __llpl_ret145;
}

uint64_t sys_exec(uint8_t* path, uint8_t* args) {
    uint64_t __llpl_ret146 = syscall2(SYS_EXEC, ((uint64_t)path), ((uint64_t)args));
    return __llpl_ret146;
}

uint64_t sys_wait(uint64_t handle) {
    uint64_t __llpl_ret147 = syscall1(SYS_WAIT, handle);
    return __llpl_ret147;
}

uint64_t sys_kill(uint64_t handle) {
    uint64_t __llpl_ret148 = syscall1(SYS_KILL, handle);
    return __llpl_ret148;
}

uint64_t sys_register(uint8_t* name) {
    uint64_t __llpl_ret149 = syscall1(SYS_REGISTER, ((uint64_t)name));
    return __llpl_ret149;
}

uint64_t sys_lookup(uint8_t* name) {
    uint64_t __llpl_ret150 = syscall1(SYS_LOOKUP, ((uint64_t)name));
    return __llpl_ret150;
}

uint8_t* sys_shm_create(uint64_t pages) {
    uint8_t* __llpl_ret151 = ((uint8_t*)syscall1(SYS_SHM_CREATE, pages));
    return __llpl_ret151;
}

uint8_t* sys_shm_map(uint64_t handle) {
    uint8_t* __llpl_ret152 = ((uint8_t*)syscall1(SYS_SHM_MAP, handle));
    return __llpl_ret152;
}

uint64_t sys_inb(uint64_t port) {
    uint64_t __llpl_ret153 = syscall1(SYS_INB, port);
    return __llpl_ret153;
}

uint64_t sys_outb(uint64_t port, uint64_t value) {
    uint64_t __llpl_ret154 = syscall2(SYS_OUTB, port, value);
    return __llpl_ret154;
}

uint64_t sys_inw(uint64_t port) {
    uint64_t __llpl_ret155 = syscall1(SYS_INW, port);
    return __llpl_ret155;
}

uint64_t sys_outw(uint64_t port, uint64_t value) {
    uint64_t __llpl_ret156 = syscall2(SYS_OUTW, port, value);
    return __llpl_ret156;
}

uint64_t sys_inl(uint64_t port) {
    uint64_t __llpl_ret157 = syscall1(SYS_INL, port);
    return __llpl_ret157;
}

uint64_t sys_outl(uint64_t port, uint64_t value) {
    uint64_t __llpl_ret158 = syscall2(SYS_OUTL, port, value);
    return __llpl_ret158;
}

uint64_t sys_bmide_base() {
    uint64_t __llpl_ret159 = syscall0(SYS_BMIDE_BASE);
    return __llpl_ret159;
}

uint64_t sys_virt_to_phys(uint64_t virt) {
    uint64_t __llpl_ret160 = syscall1(SYS_VIRT_TO_PHYS, virt);
    return __llpl_ret160;
}

uint8_t* sys_nic_mmap() {
    uint8_t* __llpl_ret161 = ((uint8_t*)syscall0(SYS_NIC_MMAP));
    return __llpl_ret161;
}

uint64_t sys_fb_info(uint64_t* out) {
    uint64_t __llpl_ret162 = syscall1(SYS_FB_INFO, ((uint64_t)out));
    return __llpl_ret162;
}

uint8_t* sys_fb_map() {
    uint8_t* __llpl_ret163 = ((uint8_t*)syscall0(SYS_FB_MAP));
    return __llpl_ret163;
}

const int64_t KEY_UP = 200;

const int64_t KEY_DOWN = 201;

const int64_t KEY_LEFT = 202;

const int64_t KEY_RIGHT = 203;

uint64_t sys_kbd_poll() {
    uint64_t __llpl_ret164 = syscall0(SYS_KBD_POLL);
    return __llpl_ret164;
}

uint64_t sys_mouse_poll() {
    uint64_t __llpl_ret165 = syscall0(SYS_MOUSE_POLL);
    return __llpl_ret165;
}

uint64_t sys_strlen(uint8_t* s) {
    uint64_t n = 0;
    while ((s[n] != 0)) {
        n = (n + 1);
    }
    uint64_t __llpl_ret166 = n;
    return __llpl_ret166;
}

uint64_t sys_puts(uint8_t* s) {
    uint64_t __llpl_ret167 = sys_pri64(s, sys_strlen(s));
    return __llpl_ret167;
}

uint64_t sys_putln(uint8_t* s) {
    uint64_t n = sys_puts(s);
    sys_pri64("\n", 1);
    uint64_t __llpl_ret168 = n;
    return __llpl_ret168;
}

uint8_t* sys_memset(uint8_t* dst, uint8_t value, uint64_t len) {
    uint64_t i = 0;
    while ((i < len)) {
        dst[i] = value;
        i = (i + 1);
    }
    uint8_t* __llpl_ret169 = dst;
    return __llpl_ret169;
}

uint8_t* sys_memcpy(uint8_t* dst, uint8_t* src, uint64_t len) {
    uint64_t i = 0;
    while ((i < len)) {
        dst[i] = src[i];
        i = (i + 1);
    }
    uint8_t* __llpl_ret170 = dst;
    return __llpl_ret170;
}

int64_t sys_strcmp(uint8_t* a, uint8_t* b) {
    uint64_t i = 0;
    while (((a[i] != 0) && (b[i] != 0))) {
        int64_t av = (((int64_t)a[i]) & 255);
        int64_t bv = (((int64_t)b[i]) & 255);
        if ((av != bv)) {
            int64_t __llpl_ret171 = (av - bv);
            return __llpl_ret171;
        }
        i = (i + 1);
    }
    int64_t __llpl_ret172 = ((((int64_t)a[i]) & 255) - (((int64_t)b[i]) & 255));
    return __llpl_ret172;
}

bool sys_streq(uint8_t* a, uint8_t* b) {
    bool __llpl_ret173 = (sys_strcmp(a, b) == 0);
    return __llpl_ret173;
}

uint8_t* sys_strcpy(uint8_t* dst, uint8_t* src) {
    uint64_t i = 0;
    while ((src[i] != 0)) {
        dst[i] = src[i];
        i = (i + 1);
    }
    dst[i] = 0;
    uint8_t* __llpl_ret174 = dst;
    return __llpl_ret174;
}

uint64_t sys_read_all(uint8_t* path, uint8_t* buf, uint64_t len) {
    uint64_t fd = sys_open(path, O_RDONLY);
    if ((fd == SYS_ERR)) {
        uint64_t __llpl_ret175 = SYS_ERR;
        return __llpl_ret175;
    }
    uint64_t n = sys_read(fd, buf, len);
    sys_close(fd);
    uint64_t __llpl_ret176 = n;
    return __llpl_ret176;
}

uint64_t sys_write_all(uint8_t* path, uint8_t* buf, uint64_t len) {
    uint64_t fd = sys_open(path, O_CREATE);
    if ((fd == SYS_ERR)) {
        uint64_t __llpl_ret177 = SYS_ERR;
        return __llpl_ret177;
    }
    uint64_t n = sys_write(fd, buf, len);
    sys_close(fd);
    uint64_t __llpl_ret178 = n;
    return __llpl_ret178;
}

uint8_t* sys_alloc_pages(uint64_t pages) {
    uint8_t* __llpl_ret179 = ((uint8_t*)sys_mmap(0, pages, 0));
    return __llpl_ret179;
}

const int64_t ALLOC_MAGIC = 5499837784062184527;

const int64_t ALLOC_FREED = 5499837784146462021;

const int64_t ALLOC_FLAG_LARGE = 1;

const int64_t PAGE_SIZE = 4096;

const int64_t LARGE_ALLOC_MIN = 2048;

const int64_t USER_PTR_MIN = 4294967296;

const int64_t ALLOC_STATE_ADDR = 4296015872;

const int64_t ALLOC_STATE_MAGIC = 5499837784364695892;

uint64_t align16(uint64_t n) {
    uint64_t __llpl_ret180 = ((n + 15) & ~15);
    return __llpl_ret180;
}

uint64_t pages_for_bytes(uint64_t n) {
    uint64_t __llpl_ret181 = (((n + PAGE_SIZE) - 1) / PAGE_SIZE);
    return __llpl_ret181;
}

AllocState* alloc_state() {
    uint8_t* p = ((uint8_t*)sys_mmap(ALLOC_STATE_ADDR, 1, 0));
    if ((p == NULL)) {
        AllocState* __llpl_ret182 = NULL;
        return __llpl_ret182;
    }
    AllocState* st = ((AllocState*)p);
    if ((st->initialized != ALLOC_STATE_MAGIC)) {
        st->heap_cur = 0;
        st->heap_end = 0;
        st->free_small = 0;
        st->initialized = ALLOC_STATE_MAGIC;
    }
    AllocState* __llpl_ret183 = st;
    return __llpl_ret183;
}

uint8_t* alloc_large(uint64_t size, uint64_t total) {
    uint64_t pages = pages_for_bytes(total);
    uint8_t* base = sys_alloc_pages(pages);
    if ((base == NULL)) {
        uint8_t* __llpl_ret184 = NULL;
        return __llpl_ret184;
    }
    AllocHeader* hdr = ((AllocHeader*)base);
    hdr->magic = ALLOC_MAGIC;
    hdr->size = size;
    hdr->pages = pages;
    hdr->base = ((uint64_t)base);
    hdr->flags = ALLOC_FLAG_LARGE;
    hdr->reserved = 0;
    uint8_t* __llpl_ret185 = (base + sizeof(AllocHeader));
    return __llpl_ret185;
}

uint8_t* alloc_small(uint64_t size, uint64_t total) {
    AllocState* st = alloc_state();
    if ((st == NULL)) {
        uint8_t* __llpl_ret186 = NULL;
        return __llpl_ret186;
    }
    AllocHeader* prev = NULL;
    if (((st->free_small != 0) && (st->free_small < USER_PTR_MIN))) {
        st->free_small = 0;
    }
    AllocHeader* cur = ((AllocHeader*)st->free_small);
    while ((cur != NULL)) {
        if ((((uint64_t)cur) < USER_PTR_MIN)) {
            st->free_small = 0;
            cur = NULL;
        } else {
            if (((cur->magic == ALLOC_FREED) && (cur->pages >= total))) {
                if ((prev == NULL)) {
                    st->free_small = cur->reserved;
                } else {
                    prev->reserved = cur->reserved;
                }
                cur->magic = ALLOC_MAGIC;
                cur->size = size;
                cur->base = 0;
                cur->flags = 0;
                cur->reserved = 0;
                uint8_t* __llpl_ret187 = (((uint8_t*)cur) + sizeof(AllocHeader));
                return __llpl_ret187;
            } else {
                prev = cur;
                cur = ((AllocHeader*)cur->reserved);
            }
        }
    }
    if (((st->heap_cur == 0) || ((st->heap_cur + total) > st->heap_end))) {
        uint64_t pages = pages_for_bytes(total);
        uint8_t* block = sys_alloc_pages(pages);
        if ((block == NULL)) {
            uint8_t* __llpl_ret188 = NULL;
            return __llpl_ret188;
        }
        st->heap_cur = ((uint64_t)block);
        st->heap_end = (st->heap_cur + (pages * PAGE_SIZE));
    }
    AllocHeader* hdr = ((AllocHeader*)st->heap_cur);
    hdr->magic = ALLOC_MAGIC;
    hdr->size = size;
    hdr->pages = total;
    hdr->base = 0;
    hdr->flags = 0;
    hdr->reserved = 0;
    st->heap_cur = (st->heap_cur + total);
    uint8_t* __llpl_ret189 = (((uint8_t*)hdr) + sizeof(AllocHeader));
    return __llpl_ret189;
}

uint8_t* sys_malloc(uint64_t size) {
    if ((size == 0)) {
        uint8_t* __llpl_ret190 = NULL;
        return __llpl_ret190;
    }
    uint64_t total = align16((size + sizeof(AllocHeader)));
    if (((size >= LARGE_ALLOC_MIN) || (total >= PAGE_SIZE))) {
        uint8_t* __llpl_ret191 = alloc_large(size, total);
        return __llpl_ret191;
    }
    uint8_t* __llpl_ret192 = alloc_small(size, total);
    return __llpl_ret192;
}

uint64_t sys_free(uint8_t* ptr) {
    if ((ptr == NULL)) {
        uint64_t __llpl_ret193 = 0;
        return __llpl_ret193;
    }
    AllocHeader* hdr = ((AllocHeader*)(ptr - sizeof(AllocHeader)));
    if ((hdr->magic != ALLOC_MAGIC)) {
        uint64_t __llpl_ret194 = SYS_ERR;
        return __llpl_ret194;
    }
    hdr->magic = ALLOC_FREED;
    if (((hdr->flags & ALLOC_FLAG_LARGE) != 0)) {
        if (((hdr->base == 0) || (hdr->pages == 0))) {
            uint64_t __llpl_ret195 = SYS_ERR;
            return __llpl_ret195;
        }
        uint64_t __llpl_ret196 = sys_munmap(hdr->base, hdr->pages);
        return __llpl_ret196;
    }
    AllocState* st = alloc_state();
    if ((st == NULL)) {
        uint64_t __llpl_ret197 = SYS_ERR;
        return __llpl_ret197;
    }
    hdr->reserved = st->free_small;
    st->free_small = ((uint64_t)hdr);
    uint64_t __llpl_ret198 = 0;
    return __llpl_ret198;
}

// Function bodies deferred until after plain class/struct definitions exist
uint64_t int_hash(int64_t self) {
    uint64_t __llpl_ret1 = ((uint64_t)self);
    return __llpl_ret1;
}
bool int_equals(int64_t self, int64_t other) {
    bool __llpl_ret2 = (self == other);
    return __llpl_ret2;
}
uint64_t uint_hash(uint64_t self) {
    uint64_t __llpl_ret3 = self;
    return __llpl_ret3;
}
bool uint_equals(uint64_t self, uint64_t other) {
    bool __llpl_ret4 = (self == other);
    return __llpl_ret4;
}
uint64_t char_hash(char self) {
    uint64_t __llpl_ret5 = ((uint64_t)self);
    return __llpl_ret5;
}
bool char_equals(char self, char other) {
    bool __llpl_ret6 = (self == other);
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
bool char_ptr_equals(char* self, char* other) {
    bool __llpl_ret8 = (llpl_strcmp(self, other) == 0);
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
bool String_equals(String* self, String* other) {
    if ((self->length != other->length)) {
        bool __llpl_ret10 = 0;
        return __llpl_ret10;
    }
    bool __llpl_ret11 = (llpl_strcmp(self->buf, other->buf) == 0);
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
bool char_ptr_op_eq(char* self, char* other) {
    bool self_null = (((uint64_t)self) == 0);
    bool other_null = (((uint64_t)other) == 0);
    if ((self_null || other_null)) {
        bool __llpl_ret21 = (self_null && other_null);
        return __llpl_ret21;
    }
    bool __llpl_ret22 = (llpl_strcmp(self, other) == 0);
    return __llpl_ret22;
}
bool char_ptr_op_ne(char* self, char* other) {
    bool __llpl_ret23 = !(self == other);
    return __llpl_ret23;
}
bool char_ptr_op_lt(char* self, char* other) {
    bool self_null = (((uint64_t)self) == 0);
    bool other_null = (((uint64_t)other) == 0);
    if ((self_null || other_null)) {
        bool __llpl_ret24 = (self_null && !other_null);
        return __llpl_ret24;
    }
    bool __llpl_ret25 = (llpl_strcmp(self, other) < 0);
    return __llpl_ret25;
}
bool char_ptr_op_gt(char* self, char* other) {
    bool self_null = (((uint64_t)self) == 0);
    bool other_null = (((uint64_t)other) == 0);
    if ((self_null || other_null)) {
        bool __llpl_ret26 = (!self_null && other_null);
        return __llpl_ret26;
    }
    bool __llpl_ret27 = (llpl_strcmp(self, other) > 0);
    return __llpl_ret27;
}
bool char_ptr_op_le(char* self, char* other) {
    bool __llpl_ret28 = !(self > other);
    return __llpl_ret28;
}
bool char_ptr_op_ge(char* self, char* other) {
    bool __llpl_ret29 = !(self < other);
    return __llpl_ret29;
}

// Symbol table for symbolized panic backtraces
LLPL_Symbol llpl_symbol_table[] = {
    { "uint_hash", (void*)uint_hash, "?", 1337 },
    { "sys_mmap", (void*)sys_mmap, "libsys.llpl", 83 },
    { "char_ptr_op_ne", (void*)char_ptr_op_ne, "?", 1448 },
    { "sys_free", (void*)sys_free, "libsys.llpl", 510 },
    { "sys_getpid", (void*)sys_getpid, "libsys.llpl", 91 },
    { "char_ptr_op_ge", (void*)char_ptr_op_ge, "?", 1474 },
    { "sys_register", (void*)sys_register, "libsys.llpl", 183 },
    { "sys_malloc", (void*)sys_malloc, "libsys.llpl", 499 },
    { "uint_compare", (void*)uint_compare, "?", 1411 },
    { "sys_exec", (void*)sys_exec, "libsys.llpl", 166 },
    { "sys_close", (void*)sys_close, "libsys.llpl", 115 },
    { "sys_msg_try_recv", (void*)sys_msg_try_recv, "libsys.llpl", 134 },
    { "sys_munmap", (void*)sys_munmap, "libsys.llpl", 87 },
    { "sys_msg_recv", (void*)sys_msg_recv, "libsys.llpl", 128 },
    { "sys_shm_create", (void*)sys_shm_create, "libsys.llpl", 200 },
    { "sys_write", (void*)sys_write, "libsys.llpl", 111 },
    { "sys_pri64", (void*)sys_pri64, "libsys.llpl", 79 },
    { "alloc_large", (void*)alloc_large, "libsys.llpl", 431 },
    { "sys_puts", (void*)sys_puts, "libsys.llpl", 304 },
    { "sys_nic_mmap", (void*)sys_nic_mmap, "libsys.llpl", 261 },
    { "alloc_small", (void*)alloc_small, "libsys.llpl", 447 },
    { "char_ptr_hash", (void*)char_ptr_hash, "?", 1359 },
    { "sys_shm_map", (void*)sys_shm_map, "libsys.llpl", 209 },
    { "sys_kill", (void*)sys_kill, "libsys.llpl", 174 },
    { "char_hash", (void*)char_hash, "?", 1346 },
    { "sys_fb_map", (void*)sys_fb_map, "libsys.llpl", 276 },
    { "sys_strcmp", (void*)sys_strcmp, "libsys.llpl", 332 },
    { "sys_strcpy", (void*)sys_strcpy, "libsys.llpl", 349 },
    { "sys_sleep", (void*)sys_sleep, "libsys.llpl", 99 },
    { "String_equals", (void*)String_equals, "?", 1388 },
    { "uint_equals", (void*)uint_equals, "?", 1340 },
    { "sys_outb", (void*)sys_outb, "libsys.llpl", 222 },
    { "char_compare", (void*)char_compare, "?", 1419 },
    { "sys_kbd_poll", (void*)sys_kbd_poll, "libsys.llpl", 287 },
    { "sys_read", (void*)sys_read, "libsys.llpl", 107 },
    { "sys_mouse_poll", (void*)sys_mouse_poll, "libsys.llpl", 292 },
    { "sys_alloc_pages", (void*)sys_alloc_pages, "libsys.llpl", 379 },
    { "sys_fb_info", (void*)sys_fb_info, "libsys.llpl", 268 },
    { "sys_memcpy", (void*)sys_memcpy, "libsys.llpl", 323 },
    { "sys_lookup", (void*)sys_lookup, "libsys.llpl", 191 },
    { "sys_outw", (void*)sys_outw, "libsys.llpl", 230 },
    { "char_equals", (void*)char_equals, "?", 1349 },
    { "char_ptr_op_lt", (void*)char_ptr_op_lt, "?", 1452 },
    { "syscall0", (void*)syscall0, "libsys.llpl", 51 },
    { "sys_inw", (void*)sys_inw, "libsys.llpl", 226 },
    { "syscall1", (void*)syscall1, "libsys.llpl", 57 },
    { "sys_memset", (void*)sys_memset, "libsys.llpl", 314 },
    { "int_hash", (void*)int_hash, "?", 1328 },
    { "sys_wait", (void*)sys_wait, "libsys.llpl", 170 },
    { "sys_streq", (void*)sys_streq, "libsys.llpl", 345 },
    { "String_hash", (void*)String_hash, "?", 1378 },
    { "sys_exit", (void*)sys_exit, "libsys.llpl", 75 },
    { "syscall3", (void*)syscall3, "libsys.llpl", 69 },
    { "int_compare", (void*)int_compare, "?", 1403 },
    { "sys_msg_send", (void*)sys_msg_send, "libsys.llpl", 124 },
    { "pages_for_bytes", (void*)pages_for_bytes, "libsys.llpl", 412 },
    { "sys_msg_reply", (void*)sys_msg_reply, "libsys.llpl", 155 },
    { "sys_outl", (void*)sys_outl, "libsys.llpl", 238 },
    { "sys_putln", (void*)sys_putln, "libsys.llpl", 308 },
    { "alloc_state", (void*)alloc_state, "libsys.llpl", 416 },
    { "int_equals", (void*)int_equals, "?", 1331 },
    { "sys_write_all", (void*)sys_write_all, "libsys.llpl", 369 },
    { "char_ptr_equals", (void*)char_ptr_equals, "?", 1370 },
    { "syscall2", (void*)syscall2, "libsys.llpl", 63 },
    { "sys_focus_state", (void*)sys_focus_state, "libsys.llpl", 151 },
    { "sys_readdir", (void*)sys_readdir, "libsys.llpl", 144 },
    { "sys_spawn", (void*)sys_spawn, "libsys.llpl", 162 },
    { "align16", (void*)align16, "libsys.llpl", 408 },
    { "sys_bmide_base", (void*)sys_bmide_base, "libsys.llpl", 246 },
    { "sys_virt_to_phys", (void*)sys_virt_to_phys, "libsys.llpl", 252 },
    { "char_ptr_op_gt", (void*)char_ptr_op_gt, "?", 1461 },
    { "char_ptr_op_eq", (void*)char_ptr_op_eq, "?", 1439 },
    { "char_ptr_op_le", (void*)char_ptr_op_le, "?", 1470 },
    { "sys_inb", (void*)sys_inb, "libsys.llpl", 218 },
    { "sys_open", (void*)sys_open, "libsys.llpl", 103 },
    { "sys_strlen", (void*)sys_strlen, "libsys.llpl", 296 },
    { "sys_inl", (void*)sys_inl, "libsys.llpl", 234 },
    { "sys_read_all", (void*)sys_read_all, "libsys.llpl", 359 },
    { "sys_yield", (void*)sys_yield, "libsys.llpl", 95 },
    { "ReflectType_new", (void*)ReflectType_new, "prelude.llpl", 130 },
    { "ReflectType_exists", (void*)ReflectType_exists, "prelude.llpl", 136 },
    { "ReflectType_name", (void*)ReflectType_name, "prelude.llpl", 140 },
    { "ReflectType_kind", (void*)ReflectType_kind, "prelude.llpl", 144 },
    { "ReflectType_size", (void*)ReflectType_size, "prelude.llpl", 148 },
    { "ReflectType_field_count", (void*)ReflectType_field_count, "prelude.llpl", 152 },
    { "ReflectType_field", (void*)ReflectType_field, "prelude.llpl", 156 },
    { "RegexMatchIterator_new", (void*)RegexMatchIterator_new, "prelude.llpl", 316 },
    { "RegexMatchIterator_advance", (void*)RegexMatchIterator_advance, "prelude.llpl", 335 },
    { "RegexMatchIterator_iter_has_next", (void*)RegexMatchIterator_iter_has_next, "prelude.llpl", 356 },
    { "RegexMatchIterator_iter_next", (void*)RegexMatchIterator_iter_next, "prelude.llpl", 364 },
    { "Vector_ParseNode_new", (void*)Vector_ParseNode_new, "?", 1004 },
    { "Vector_ParseNode_push", (void*)Vector_ParseNode_push, "?", 1018 },
    { "Vector_ParseNode_grow", (void*)Vector_ParseNode_grow, "?", 1026 },
    { "Vector_ParseNode_get", (void*)Vector_ParseNode_get, "?", 1035 },
    { "Vector_ParseNode_set", (void*)Vector_ParseNode_set, "?", 1042 },
    { "Vector_ParseNode_pop", (void*)Vector_ParseNode_pop, "?", 1049 },
    { "Vector_ParseNode_len", (void*)Vector_ParseNode_len, "?", 1054 },
    { "Vector_ParseNode_is_empty", (void*)Vector_ParseNode_is_empty, "?", 1058 },
    { "Vector_ParseNode_as_slice", (void*)Vector_ParseNode_as_slice, "?", 1068 },
    { "String_new", (void*)String_new, "prelude.llpl", 469 },
    { "String_byte_len", (void*)String_byte_len, "prelude.llpl", 480 },
    { "String_len", (void*)String_len, "prelude.llpl", 484 },
    { "String_is_utf8", (void*)String_is_utf8, "prelude.llpl", 488 },
    { "String_byte_index", (void*)String_byte_index, "prelude.llpl", 492 },
    { "String_char_index", (void*)String_char_index, "prelude.llpl", 499 },
    { "String_codepoint_at", (void*)String_codepoint_at, "prelude.llpl", 506 },
    { "String_c_str", (void*)String_c_str, "prelude.llpl", 516 },
    { "String_byte_at", (void*)String_byte_at, "prelude.llpl", 520 },
    { "String_op_index", (void*)String_op_index, "prelude.llpl", 524 },
    { "String_iter_reset", (void*)String_iter_reset, "prelude.llpl", 532 },
    { "String_iter_has_next", (void*)String_iter_has_next, "prelude.llpl", 536 },
    { "String_iter_next", (void*)String_iter_next, "prelude.llpl", 540 },
    { "String_byte_set", (void*)String_byte_set, "prelude.llpl", 546 },
    { "String_op_eq_char_ptr", (void*)String_op_eq_char_ptr, "prelude.llpl", 550 },
    { "String_op_ne_char_ptr", (void*)String_op_ne_char_ptr, "prelude.llpl", 554 },
    { "String_op_lt_char_ptr", (void*)String_op_lt_char_ptr, "prelude.llpl", 558 },
    { "String_op_gt_char_ptr", (void*)String_op_gt_char_ptr, "prelude.llpl", 562 },
    { "String_op_eq_String", (void*)String_op_eq_String, "prelude.llpl", 573 },
    { "String_op_ne_String", (void*)String_op_ne_String, "prelude.llpl", 577 },
    { "String_op_lt_String", (void*)String_op_lt_String, "prelude.llpl", 581 },
    { "String_op_gt_String", (void*)String_op_gt_String, "prelude.llpl", 585 },
    { "String_op_add", (void*)String_op_add, "prelude.llpl", 595 },
    { "String_byte_substring", (void*)String_byte_substring, "prelude.llpl", 606 },
    { "String_substring", (void*)String_substring, "prelude.llpl", 627 },
    { "String_utf8_substring", (void*)String_utf8_substring, "prelude.llpl", 648 },
    { "String_byte_find", (void*)String_byte_find, "prelude.llpl", 653 },
    { "String_find", (void*)String_find, "prelude.llpl", 678 },
    { "String_contains", (void*)String_contains, "prelude.llpl", 686 },
    { "String_starts_with", (void*)String_starts_with, "prelude.llpl", 690 },
    { "String_ends_with", (void*)String_ends_with, "prelude.llpl", 705 },
    { "String_to_upper", (void*)String_to_upper, "prelude.llpl", 721 },
    { "String_to_lower", (void*)String_to_lower, "prelude.llpl", 737 },
    { "String_trim", (void*)String_trim, "prelude.llpl", 754 },
    { "Regex_new", (void*)Regex_new, "prelude.llpl", 376 },
    { "Regex_match", (void*)Regex_match, "prelude.llpl", 386 },
    { "Regex_captures", (void*)Regex_captures, "prelude.llpl", 390 },
    { "Regex_find_all", (void*)Regex_find_all, "prelude.llpl", 396 },
    { "Regex_replace", (void*)Regex_replace, "prelude.llpl", 403 },
    { "Regex_replace_all", (void*)Regex_replace_all, "prelude.llpl", 418 },
    { "Regex_source", (void*)Regex_source, "prelude.llpl", 439 },
    { "ReflectField_new", (void*)ReflectField_new, "prelude.llpl", 100 },
    { "ReflectField_exists", (void*)ReflectField_exists, "prelude.llpl", 106 },
    { "ReflectField_name", (void*)ReflectField_name, "prelude.llpl", 110 },
    { "ReflectField_type_name", (void*)ReflectField_type_name, "prelude.llpl", 114 },
    { "ReflectField_offset", (void*)ReflectField_offset, "prelude.llpl", 118 },
    { "ReflectField_size", (void*)ReflectField_size, "prelude.llpl", 122 },
    { "ParseNode_new", (void*)ParseNode_new, "prelude.llpl", 1202 },
    { "ParseNode_name", (void*)ParseNode_name, "prelude.llpl", 1214 },
    { "ParseNode_text", (void*)ParseNode_text, "prelude.llpl", 1218 },
    { "ParseNode_child", (void*)ParseNode_child, "prelude.llpl", 1222 },
    { "ParseNode_child_count", (void*)ParseNode_child_count, "prelude.llpl", 1226 },
    { "RegexMatch_new", (void*)RegexMatch_new, "prelude.llpl", 180 },
    { "RegexMatch_is_match", (void*)RegexMatch_is_match, "prelude.llpl", 198 },
    { "RegexMatch_group_count", (void*)RegexMatch_group_count, "prelude.llpl", 202 },
    { "RegexMatch_has_group", (void*)RegexMatch_has_group, "prelude.llpl", 206 },
    { "RegexMatch_group_start", (void*)RegexMatch_group_start, "prelude.llpl", 215 },
    { "RegexMatch_group_end", (void*)RegexMatch_group_end, "prelude.llpl", 227 },
    { "RegexMatch_group", (void*)RegexMatch_group, "prelude.llpl", 239 },
    { "RegexMatch_expand", (void*)RegexMatch_expand, "prelude.llpl", 254 },
    { "OwnedBuffer_new", (void*)OwnedBuffer_new, "prelude.llpl", 815 },
    { "OwnedBuffer_free", (void*)OwnedBuffer_free, "prelude.llpl", 824 },
    { "OwnedBuffer_data", (void*)OwnedBuffer_data, "prelude.llpl", 832 },
    { "OwnedBuffer_len", (void*)OwnedBuffer_len, "prelude.llpl", 836 },
    { "OwnedBuffer_is_null", (void*)OwnedBuffer_is_null, "prelude.llpl", 840 },
    { "OwnedBuffer_byte_at", (void*)OwnedBuffer_byte_at, "prelude.llpl", 844 },
    { "OwnedBuffer_set", (void*)OwnedBuffer_set, "prelude.llpl", 851 },
    { "OwnedBuffer_as_slice", (void*)OwnedBuffer_as_slice, "prelude.llpl", 858 },
    { "OwnedBuffer_take", (void*)OwnedBuffer_take, "prelude.llpl", 865 },
};
uint64_t llpl_symbol_table_count = 168;


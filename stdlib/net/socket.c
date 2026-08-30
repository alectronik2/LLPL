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
typedef struct Result_bool_char_ptr Result_bool_char_ptr;
Result_bool_char_ptr* Result_bool_char_ptr_new();
void Result_bool_char_ptr_destroy(void* ptr);
void Result_bool_char_ptr_set_ok(Result_bool_char_ptr* self, int v);
void Result_bool_char_ptr_set_err(Result_bool_char_ptr* self, char* e);
void Result_bool_char_ptr_set_err_with_trace(Result_bool_char_ptr* self, char* e, char* t);
int Result_bool_char_ptr_get_ok(Result_bool_char_ptr* self);
char* Result_bool_char_ptr_get_err(Result_bool_char_ptr* self);
char* Result_bool_char_ptr_get_trace(Result_bool_char_ptr* self);
int Result_bool_char_ptr_is_ok(Result_bool_char_ptr* self);
int Result_bool_char_ptr_is_err(Result_bool_char_ptr* self);
typedef struct Result_Socket_char_ptr Result_Socket_char_ptr;
Result_Socket_char_ptr* Result_Socket_char_ptr_new();
void Result_Socket_char_ptr_destroy(void* ptr);
void Result_Socket_char_ptr_set_ok(Result_Socket_char_ptr* self, Socket* v);
void Result_Socket_char_ptr_set_err(Result_Socket_char_ptr* self, char* e);
void Result_Socket_char_ptr_set_err_with_trace(Result_Socket_char_ptr* self, char* e, char* t);
Socket* Result_Socket_char_ptr_get_ok(Result_Socket_char_ptr* self);
char* Result_Socket_char_ptr_get_err(Result_Socket_char_ptr* self);
char* Result_Socket_char_ptr_get_trace(Result_Socket_char_ptr* self);
int Result_Socket_char_ptr_is_ok(Result_Socket_char_ptr* self);
int Result_Socket_char_ptr_is_err(Result_Socket_char_ptr* self);
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
typedef struct Result_std_net_Socket_char_ptr Result_std_net_Socket_char_ptr;
typedef struct std_net_Socket std_net_Socket;
Result_std_net_Socket_char_ptr* Result_std_net_Socket_char_ptr_new();
void Result_std_net_Socket_char_ptr_destroy(void* ptr);
void Result_std_net_Socket_char_ptr_set_ok(Result_std_net_Socket_char_ptr* self, std_net_Socket* v);
void Result_std_net_Socket_char_ptr_set_err(Result_std_net_Socket_char_ptr* self, char* e);
void Result_std_net_Socket_char_ptr_set_err_with_trace(Result_std_net_Socket_char_ptr* self, char* e, char* t);
std_net_Socket* Result_std_net_Socket_char_ptr_get_ok(Result_std_net_Socket_char_ptr* self);
char* Result_std_net_Socket_char_ptr_get_err(Result_std_net_Socket_char_ptr* self);
char* Result_std_net_Socket_char_ptr_get_trace(Result_std_net_Socket_char_ptr* self);
int Result_std_net_Socket_char_ptr_is_ok(Result_std_net_Socket_char_ptr* self);
int Result_std_net_Socket_char_ptr_is_err(Result_std_net_Socket_char_ptr* self);

// Monomorphized generic instantiations - full bodies
struct Slice_char {
    char* ptr;
    uint64_t len;
};
struct Result_bool_char_ptr {
    RefCount ref_count;
    int ok;
    int value;
    char* error;
    char* trace;
};

Result_bool_char_ptr* Result_bool_char_ptr_new() {
    Result_bool_char_ptr* self = (Result_bool_char_ptr*)rc_alloc(sizeof(Result_bool_char_ptr));
    if (!self) return NULL;
    rc_init(&self->ref_count);

    self->ok = 0;
    self->trace = NULL;
    return self;
}

void Result_bool_char_ptr_destroy(void* ptr) {
    Result_bool_char_ptr* self = (Result_bool_char_ptr*)ptr;
}

void Result_bool_char_ptr_set_ok(Result_bool_char_ptr* self, int v) {
    self->ok = 1;
    self->value = v;
}

void Result_bool_char_ptr_set_err(Result_bool_char_ptr* self, char* e) {
    self->ok = 0;
    self->error = e;
    self->trace = NULL;
}

void Result_bool_char_ptr_set_err_with_trace(Result_bool_char_ptr* self, char* e, char* t) {
    self->ok = 0;
    self->error = e;
    self->trace = t;
}

int Result_bool_char_ptr_get_ok(Result_bool_char_ptr* self) {
    int __llpl_ret30 = self->value;
    return __llpl_ret30;
}

char* Result_bool_char_ptr_get_err(Result_bool_char_ptr* self) {
    char* __llpl_ret31 = self->error;
    return __llpl_ret31;
}

char* Result_bool_char_ptr_get_trace(Result_bool_char_ptr* self) {
    char* __llpl_ret32 = self->trace;
    return __llpl_ret32;
}

int Result_bool_char_ptr_is_ok(Result_bool_char_ptr* self) {
    int __llpl_ret33 = self->ok;
    return __llpl_ret33;
}

int Result_bool_char_ptr_is_err(Result_bool_char_ptr* self) {
    int __llpl_ret34 = !self->ok;
    return __llpl_ret34;
}

struct Result_Socket_char_ptr {
    RefCount ref_count;
    int ok;
    Socket* value;
    char* error;
    char* trace;
};

Result_Socket_char_ptr* Result_Socket_char_ptr_new() {
    Result_Socket_char_ptr* self = (Result_Socket_char_ptr*)rc_alloc(sizeof(Result_Socket_char_ptr));
    if (!self) return NULL;
    rc_init(&self->ref_count);

    self->ok = 0;
    self->trace = NULL;
    return self;
}

void Result_Socket_char_ptr_destroy(void* ptr) {
    Result_Socket_char_ptr* self = (Result_Socket_char_ptr*)ptr;
    if (self->value) rc_release(self->value, Socket_destroy);
}

void Result_Socket_char_ptr_set_ok(Result_Socket_char_ptr* self, Socket* v) {
    self->ok = 1;
    self->value = v;
}

void Result_Socket_char_ptr_set_err(Result_Socket_char_ptr* self, char* e) {
    self->ok = 0;
    self->error = e;
    self->trace = NULL;
}

void Result_Socket_char_ptr_set_err_with_trace(Result_Socket_char_ptr* self, char* e, char* t) {
    self->ok = 0;
    self->error = e;
    self->trace = t;
}

Socket* Result_Socket_char_ptr_get_ok(Result_Socket_char_ptr* self) {
    Socket* __llpl_ret35 = self->value;
    return __llpl_ret35;
}

char* Result_Socket_char_ptr_get_err(Result_Socket_char_ptr* self) {
    char* __llpl_ret36 = self->error;
    return __llpl_ret36;
}

char* Result_Socket_char_ptr_get_trace(Result_Socket_char_ptr* self) {
    char* __llpl_ret37 = self->trace;
    return __llpl_ret37;
}

int Result_Socket_char_ptr_is_ok(Result_Socket_char_ptr* self) {
    int __llpl_ret38 = self->ok;
    return __llpl_ret38;
}

int Result_Socket_char_ptr_is_err(Result_Socket_char_ptr* self) {
    int __llpl_ret39 = !self->ok;
    return __llpl_ret39;
}

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
    int64_t __llpl_ret40 = self->value;
    return __llpl_ret40;
}

char* Result_int_char_ptr_get_err(Result_int_char_ptr* self) {
    char* __llpl_ret41 = self->error;
    return __llpl_ret41;
}

char* Result_int_char_ptr_get_trace(Result_int_char_ptr* self) {
    char* __llpl_ret42 = self->trace;
    return __llpl_ret42;
}

int Result_int_char_ptr_is_ok(Result_int_char_ptr* self) {
    int __llpl_ret43 = self->ok;
    return __llpl_ret43;
}

int Result_int_char_ptr_is_err(Result_int_char_ptr* self) {
    int __llpl_ret44 = !self->ok;
    return __llpl_ret44;
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
    String* __llpl_ret45 = self->value;
    return __llpl_ret45;
}

char* Result_String_char_ptr_get_err(Result_String_char_ptr* self) {
    char* __llpl_ret46 = self->error;
    return __llpl_ret46;
}

char* Result_String_char_ptr_get_trace(Result_String_char_ptr* self) {
    char* __llpl_ret47 = self->trace;
    return __llpl_ret47;
}

int Result_String_char_ptr_is_ok(Result_String_char_ptr* self) {
    int __llpl_ret48 = self->ok;
    return __llpl_ret48;
}

int Result_String_char_ptr_is_err(Result_String_char_ptr* self) {
    int __llpl_ret49 = !self->ok;
    return __llpl_ret49;
}

struct Result_std_net_Socket_char_ptr {
    RefCount ref_count;
    int ok;
    std_net_Socket* value;
    char* error;
    char* trace;
};

Result_std_net_Socket_char_ptr* Result_std_net_Socket_char_ptr_new() {
    Result_std_net_Socket_char_ptr* self = (Result_std_net_Socket_char_ptr*)rc_alloc(sizeof(Result_std_net_Socket_char_ptr));
    if (!self) return NULL;
    rc_init(&self->ref_count);

    self->ok = 0;
    self->trace = NULL;
    return self;
}

void Result_std_net_Socket_char_ptr_destroy(void* ptr) {
    Result_std_net_Socket_char_ptr* self = (Result_std_net_Socket_char_ptr*)ptr;
    if (self->value) rc_release(self->value, std_net_Socket_destroy);
}

void Result_std_net_Socket_char_ptr_set_ok(Result_std_net_Socket_char_ptr* self, std_net_Socket* v) {
    self->ok = 1;
    self->value = v;
}

void Result_std_net_Socket_char_ptr_set_err(Result_std_net_Socket_char_ptr* self, char* e) {
    self->ok = 0;
    self->error = e;
    self->trace = NULL;
}

void Result_std_net_Socket_char_ptr_set_err_with_trace(Result_std_net_Socket_char_ptr* self, char* e, char* t) {
    self->ok = 0;
    self->error = e;
    self->trace = t;
}

std_net_Socket* Result_std_net_Socket_char_ptr_get_ok(Result_std_net_Socket_char_ptr* self) {
    std_net_Socket* __llpl_ret50 = self->value;
    return __llpl_ret50;
}

char* Result_std_net_Socket_char_ptr_get_err(Result_std_net_Socket_char_ptr* self) {
    char* __llpl_ret51 = self->error;
    return __llpl_ret51;
}

char* Result_std_net_Socket_char_ptr_get_trace(Result_std_net_Socket_char_ptr* self) {
    char* __llpl_ret52 = self->trace;
    return __llpl_ret52;
}

int Result_std_net_Socket_char_ptr_is_ok(Result_std_net_Socket_char_ptr* self) {
    int __llpl_ret53 = self->ok;
    return __llpl_ret53;
}

int Result_std_net_Socket_char_ptr_is_err(Result_std_net_Socket_char_ptr* self) {
    int __llpl_ret54 = !self->ok;
    return __llpl_ret54;
}


typedef struct EmbeddedFile EmbeddedFile;
typedef struct ReflectField ReflectField;
typedef struct ReflectType ReflectType;
typedef struct RegexMatch RegexMatch;
typedef struct RegexMatchIterator RegexMatchIterator;
typedef struct Regex Regex;
typedef struct String String;
typedef struct OwnedBuffer OwnedBuffer;
typedef struct std_net_SockAddrIn std_net_SockAddrIn;
typedef struct std_net_Socket std_net_Socket;
typedef struct std_net_TcpServer std_net_TcpServer;
typedef struct std_net_TcpClient std_net_TcpClient;
typedef struct std_net_UdpSocket std_net_UdpSocket;

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
std_net_SockAddrIn* std_net_SockAddrIn_new();
void std_net_SockAddrIn_set_port(std_net_SockAddrIn* self, uint16_t port);
void std_net_SockAddrIn_set_addr(std_net_SockAddrIn* self, uint8_t a, uint8_t b, uint8_t c, uint8_t d);
void std_net_SockAddrIn_set_addr_any(std_net_SockAddrIn* self);
uint16_t std_net_SockAddrIn_get_port(std_net_SockAddrIn* self);
extern int64_t socket(int64_t domain, int64_t type, int64_t protocol);
extern int64_t bind(int64_t sockfd, void* addr, uint64_t addrlen);
extern int64_t listen(int64_t sockfd, int64_t backlog);
extern int64_t accept(int64_t sockfd, void* addr, uint64_t* addrlen);
extern int64_t connect(int64_t sockfd, void* addr, uint64_t addrlen);
extern int64_t send(int64_t sockfd, void* buf, uint64_t len, int64_t flags);
extern int64_t recv(int64_t sockfd, void* buf, uint64_t len, int64_t flags);
extern int64_t sendto(int64_t sockfd, void* buf, uint64_t len, int64_t flags, void* dest_addr, uint64_t addrlen);
extern int64_t recvfrom(int64_t sockfd, void* buf, uint64_t len, int64_t flags, void* src_addr, uint64_t* addrlen);
extern int64_t shutdown(int64_t sockfd, int64_t how);
extern int64_t close(int64_t fd);
extern int64_t setsockopt(int64_t sockfd, int64_t level, int64_t optname, void* optval, uint64_t optlen);
extern uint16_t htons(uint16_t hostshort);
extern uint16_t ntohs(uint16_t netshort);
extern uint32_t htonl(uint32_t hostlong);
extern uint32_t ntohl(uint32_t netlong);
std_net_Socket* std_net_Socket_new(int64_t dom, int64_t type, int64_t proto);
void std_net_Socket_destroy(void* ptr);
int std_net_Socket_is_valid(std_net_Socket* self);
Result_bool_char_ptr* std_net_Socket_bind_addr(std_net_Socket* self, SockAddrIn* addr);
Result_bool_char_ptr* std_net_Socket_listen_backlog(std_net_Socket* self, int64_t backlog);
Result_Socket_char_ptr* std_net_Socket_accept_connection(std_net_Socket* self);
Result_bool_char_ptr* std_net_Socket_connect_to(std_net_Socket* self, SockAddrIn* addr);
Result_int_char_ptr* std_net_Socket_send_data(std_net_Socket* self, char* buffer, uint64_t size);
Result_int_char_ptr* std_net_Socket_recv_data(std_net_Socket* self, char* buffer, uint64_t size);
Result_int_char_ptr* std_net_Socket_send_string(std_net_Socket* self, String* s);
Result_String_char_ptr* std_net_Socket_recv_string(std_net_Socket* self, uint64_t max_size);
Result_bool_char_ptr* std_net_Socket_set_reuse_addr(std_net_Socket* self, int enable);
Result_bool_char_ptr* std_net_Socket_shutdown_socket(std_net_Socket* self, int64_t how);
std_net_TcpServer* std_net_TcpServer_new(uint16_t port);
Result_bool_char_ptr* std_net_TcpServer_start(std_net_TcpServer* self, int64_t backlog);
Result_std_net_Socket_char_ptr* std_net_TcpServer_accept(std_net_TcpServer* self);
int std_net_TcpServer_is_valid(std_net_TcpServer* self);
std_net_TcpClient* std_net_TcpClient_new();
Result_bool_char_ptr* std_net_TcpClient_connect(std_net_TcpClient* self, uint8_t host_a, uint8_t host_b, uint8_t host_c, uint8_t host_d, uint16_t port);
Result_int_char_ptr* std_net_TcpClient_send(std_net_TcpClient* self, String* data);
Result_String_char_ptr* std_net_TcpClient_recv(std_net_TcpClient* self, uint64_t max_size);
int std_net_TcpClient_is_valid(std_net_TcpClient* self);
void std_net_TcpClient_close(std_net_TcpClient* self);
std_net_UdpSocket* std_net_UdpSocket_new(uint16_t port);
Result_bool_char_ptr* std_net_UdpSocket_bind_socket(std_net_UdpSocket* self);
Result_int_char_ptr* std_net_UdpSocket_send_to(std_net_UdpSocket* self, char* data, uint64_t size, std_net_SockAddrIn* dest_addr);
Result_int_char_ptr* std_net_UdpSocket_recv_from(std_net_UdpSocket* self, char* buffer, uint64_t size);
int std_net_UdpSocket_is_valid(std_net_UdpSocket* self);

extern const int64_t std_net_AF_INET;
extern const int64_t std_net_AF_INET6;
extern const int64_t std_net_SOCK_STREAM;
extern const int64_t std_net_SOCK_DGRAM;
extern const int64_t std_net_SOCK_RAW;
extern const int64_t std_net_IPPROTO_TCP;
extern const int64_t std_net_IPPROTO_UDP;
extern const int64_t std_net_IPPROTO_ICMP;
extern const int64_t std_net_SOL_SOCKET;
extern const int64_t std_net_SO_REUSEADDR;
extern const int64_t std_net_SO_KEEPALIVE;
extern const int64_t std_net_SO_RCVTIMEO;
extern const int64_t std_net_SO_SNDTIMEO;
extern const int64_t std_net_SHUT_RD;
extern const int64_t std_net_SHUT_WR;
extern const int64_t std_net_SHUT_RDWR;


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
    int __llpl_ret55 = (((uint64_t)self->raw) != 0);
    return __llpl_ret55;
}

char* ReflectField_name(ReflectField* self) {
    char* __llpl_ret56 = llpl_reflect_field_name(self->raw);
    return __llpl_ret56;
}

char* ReflectField_type_name(ReflectField* self) {
    char* __llpl_ret57 = llpl_reflect_field_type_name(self->raw);
    return __llpl_ret57;
}

int64_t ReflectField_offset(ReflectField* self) {
    int64_t __llpl_ret58 = ((int64_t)llpl_reflect_field_offset(self->raw));
    return __llpl_ret58;
}

int64_t ReflectField_size(ReflectField* self) {
    int64_t __llpl_ret59 = ((int64_t)llpl_reflect_field_size(self->raw));
    return __llpl_ret59;
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
    int __llpl_ret60 = (((uint64_t)self->raw) != 0);
    return __llpl_ret60;
}

char* ReflectType_name(ReflectType* self) {
    char* __llpl_ret61 = llpl_reflect_type_name(self->raw);
    return __llpl_ret61;
}

char* ReflectType_kind(ReflectType* self) {
    char* __llpl_ret62 = llpl_reflect_type_kind(self->raw);
    return __llpl_ret62;
}

int64_t ReflectType_size(ReflectType* self) {
    int64_t __llpl_ret63 = ((int64_t)llpl_reflect_type_size(self->raw));
    return __llpl_ret63;
}

int64_t ReflectType_field_count(ReflectType* self) {
    int64_t __llpl_ret64 = ((int64_t)llpl_reflect_field_count(self->raw));
    return __llpl_ret64;
}

ReflectField* ReflectType_field(ReflectType* self, int64_t index) {
    if ((index < 0)) {
        ReflectField* __llpl_ret65 = ReflectField_new(NULL);
        return __llpl_ret65;
    }
    ReflectField* __llpl_ret66 = ReflectField_new(llpl_reflect_field(self->raw, ((uint64_t)index)));
    return __llpl_ret66;
}


ReflectType* reflect_type(char* name) {
    ReflectType* __llpl_ret67 = ReflectType_new(llpl_reflect_type(name));
    return __llpl_ret67;
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
    int __llpl_ret68 = self->matched;
    return __llpl_ret68;
}

int64_t RegexMatch_group_count(RegexMatch* self) {
    int64_t __llpl_ret69 = ((int64_t)llpl_regex_group_count(self->pattern));
    return __llpl_ret69;
}

int RegexMatch_has_group(RegexMatch* self, int64_t index) {
    if ((index < 0)) {
        int __llpl_ret70 = 0;
        return __llpl_ret70;
    }
    int64_t start = 0;
    int64_t end = 0;
    int __llpl_ret71 = llpl_regex_capture_bounds(self->pattern, self->text, ((uint64_t)index), &start, &end);
    return __llpl_ret71;
}

int64_t RegexMatch_group_start(RegexMatch* self, int64_t index) {
    if ((index < 0)) {
        int64_t __llpl_ret72 = -1;
        return __llpl_ret72;
    }
    int64_t start = 0;
    int64_t end = 0;
    if (llpl_regex_capture_bounds(self->pattern, self->text, ((uint64_t)index), &start, &end)) {
        int64_t __llpl_ret73 = (start + self->base_offset);
        return __llpl_ret73;
    }
    int64_t __llpl_ret74 = -1;
    return __llpl_ret74;
}

int64_t RegexMatch_group_end(RegexMatch* self, int64_t index) {
    if ((index < 0)) {
        int64_t __llpl_ret75 = -1;
        return __llpl_ret75;
    }
    int64_t start = 0;
    int64_t end = 0;
    if (llpl_regex_capture_bounds(self->pattern, self->text, ((uint64_t)index), &start, &end)) {
        int64_t __llpl_ret76 = (end + self->base_offset);
        return __llpl_ret76;
    }
    int64_t __llpl_ret77 = -1;
    return __llpl_ret77;
}

String* RegexMatch_group(RegexMatch* self, int64_t index) {
    if ((index < 0)) {
        String* __llpl_ret78 = String_new("");
        return __llpl_ret78;
    }
    char* raw = llpl_regex_capture(self->pattern, self->text, ((uint64_t)index));
    String* out = String_new(raw);
    llpl_free(raw);
    String* __llpl_ret79 = out;
    return __llpl_ret79;
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
    String* __llpl_ret80 = result;
    return __llpl_ret80;
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
        int __llpl_ret81 = 0;
        return __llpl_ret81;
    }
    RegexMatch* m = RegexMatch_new(self->pattern, (self->text + self->pos), self->pos);
    if (!RegexMatch_is_match(m)) {
        self->done = 1;
        int __llpl_ret82 = 0;
        return __llpl_ret82;
    }
    self->current = m;
    int64_t end_in_suffix = (RegexMatch_group_end(m, 0) - self->pos);
    int64_t start_in_suffix = (RegexMatch_group_start(m, 0) - self->pos);
    if ((end_in_suffix == start_in_suffix)) {
        self->pos = ((self->pos + end_in_suffix) + 1);
    } else {
        self->pos = (self->pos + end_in_suffix);
    }
    int __llpl_ret83 = 1;
    return __llpl_ret83;
}

int RegexMatchIterator_iter_has_next(RegexMatchIterator* self) {
    if (self->has_current) {
        int __llpl_ret84 = 1;
        return __llpl_ret84;
    }
    self->has_current = RegexMatchIterator_advance(self);
    int __llpl_ret85 = self->has_current;
    return __llpl_ret85;
}

RegexMatch* RegexMatchIterator_iter_next(RegexMatchIterator* self) {
    if (!self->has_current) {
        RegexMatchIterator_advance(self);
    }
    self->has_current = 0;
    RegexMatch* __llpl_ret86 = self->current;
    return __llpl_ret86;
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
    int __llpl_ret87 = llpl_regex_match(self->pattern, text);
    return __llpl_ret87;
}

RegexMatch* Regex_captures(Regex* self, char* text) {
    RegexMatch* __llpl_ret88 = RegexMatch_new(self->pattern, text, 0);
    return __llpl_ret88;
}

RegexMatchIterator* Regex_find_all(Regex* self, char* text) {
    RegexMatchIterator* __llpl_ret89 = RegexMatchIterator_new(self->pattern, text);
    return __llpl_ret89;
}

String* Regex_replace(Regex* self, char* text, char* replacement) {
    RegexMatch* m = Regex_captures(self, text);
    if (!RegexMatch_is_match(m)) {
        String* __llpl_ret90 = String_new(text);
        return __llpl_ret90;
    }
    String* ts = String_new(text);
    int64_t start = RegexMatch_group_start(m, 0);
    int64_t end = RegexMatch_group_end(m, 0);
    String* result = String_byte_substring(ts, 0, start);
    result = String_op_add(result, String_c_str(RegexMatch_expand(m, replacement)));
    result = String_op_add(result, String_c_str(String_byte_substring(ts, end, (String_byte_len(ts) - end))));
    String* __llpl_ret91 = result;
    return __llpl_ret91;
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
    String* __llpl_ret92 = result;
    return __llpl_ret92;
}

char* Regex_source(Regex* self) {
    char* __llpl_ret93 = self->pattern;
    return __llpl_ret93;
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
    int64_t __llpl_ret94 = self->length;
    return __llpl_ret94;
}

int64_t String_len(String* self) {
    int64_t __llpl_ret95 = ((int64_t)llpl_utf8_len(self->buf));
    return __llpl_ret95;
}

int String_is_utf8(String* self) {
    int __llpl_ret96 = llpl_utf8_valid(self->buf);
    return __llpl_ret96;
}

int64_t String_byte_index(String* self, int64_t char_index) {
    if ((char_index < 0)) {
        int64_t __llpl_ret97 = 0;
        return __llpl_ret97;
    }
    int64_t __llpl_ret98 = ((int64_t)llpl_utf8_byte_offset(self->buf, ((uint64_t)char_index)));
    return __llpl_ret98;
}

int64_t String_char_index(String* self, int64_t byte_offset) {
    if ((byte_offset < 0)) {
        int64_t __llpl_ret99 = 0;
        return __llpl_ret99;
    }
    int64_t __llpl_ret100 = ((int64_t)llpl_utf8_char_index(self->buf, ((uint64_t)byte_offset)));
    return __llpl_ret100;
}

uint64_t String_codepoint_at(String* self, int64_t char_index) {
    if ((char_index < 0)) {
        uint64_t __llpl_ret101 = 0;
        return __llpl_ret101;
    }
    uint64_t __llpl_ret102 = llpl_utf8_codepoint_at(self->buf, ((uint64_t)char_index));
    return __llpl_ret102;
}

char* String_c_str(String* self) {
    char* __llpl_ret103 = self->buf;
    return __llpl_ret103;
}

char String_byte_at(String* self, int64_t index) {
    char __llpl_ret104 = self->buf[index];
    return __llpl_ret104;
}

uint64_t String_op_index(String* self, int64_t index) {
    uint64_t __llpl_ret105 = String_codepoint_at(self, index);
    return __llpl_ret105;
}

void String_iter_reset(String* self) {
    self->iter_pos = 0;
}

int String_iter_has_next(String* self) {
    int __llpl_ret106 = (self->iter_pos < String_len(self));
    return __llpl_ret106;
}

uint64_t String_iter_next(String* self) {
    uint64_t c = String_codepoint_at(self, self->iter_pos);
    self->iter_pos = (self->iter_pos + 1);
    uint64_t __llpl_ret107 = c;
    return __llpl_ret107;
}

void String_byte_set(String* self, int64_t index, char value) {
    self->buf[index] = value;
}

int String_op_eq(String* self, char* other) {
    int __llpl_ret108 = (llpl_strcmp(self->buf, other) == 0);
    return __llpl_ret108;
}

int String_op_ne(String* self, char* other) {
    int __llpl_ret109 = !String_op_eq(self, other);
    return __llpl_ret109;
}

int String_op_lt(String* self, char* other) {
    int __llpl_ret110 = (llpl_strcmp(self->buf, other) < 0);
    return __llpl_ret110;
}

int String_op_gt(String* self, char* other) {
    int __llpl_ret111 = (llpl_strcmp(self->buf, other) > 0);
    return __llpl_ret111;
}

String* String_op_add(String* self, char* other) {
    int64_t other_len = ((int64_t)llpl_strlen(other));
    int64_t total = (self->length + other_len);
    char* joined = llpl_alloc(((uint64_t)(total + 1)));
    llpl_memcpy(joined, self->buf, ((uint64_t)self->length));
    llpl_memcpy((joined + self->length), other, ((uint64_t)(other_len + 1)));
    String* __llpl_ret112 = String_new(joined);
    return __llpl_ret112;
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
    String* __llpl_ret113 = String_new(piece);
    return __llpl_ret113;
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
    String* __llpl_ret114 = String_byte_substring(self, byte_start, (byte_end - byte_start));
    return __llpl_ret114;
}

String* String_utf8_substring(String* self, int64_t start, int64_t count) {
    String* __llpl_ret115 = String_substring(self, start, count);
    return __llpl_ret115;
}

int64_t String_byte_find(String* self, char* needle) {
    int64_t needle_len = ((int64_t)llpl_strlen(needle));
    if ((needle_len == 0)) {
        int64_t __llpl_ret116 = 0;
        return __llpl_ret116;
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
            int64_t __llpl_ret117 = i;
            return __llpl_ret117;
        }
        i = (i + 1);
    }
    int64_t __llpl_ret118 = -1;
    return __llpl_ret118;
}

int64_t String_find(String* self, char* needle) {
    int64_t byte_pos = String_byte_find(self, needle);
    if ((byte_pos < 0)) {
        int64_t __llpl_ret119 = -1;
        return __llpl_ret119;
    }
    int64_t __llpl_ret120 = String_char_index(self, byte_pos);
    return __llpl_ret120;
}

int String_contains(String* self, char* needle) {
    int __llpl_ret121 = (String_find(self, needle) >= 0);
    return __llpl_ret121;
}

int String_starts_with(String* self, char* prefix) {
    int64_t prefix_len = ((int64_t)llpl_strlen(prefix));
    if ((prefix_len > self->length)) {
        int __llpl_ret122 = 0;
        return __llpl_ret122;
    }
    int64_t i = 0;
    while ((i < prefix_len)) {
        if ((self->buf[i] != prefix[i])) {
            int __llpl_ret123 = 0;
            return __llpl_ret123;
        }
        i = (i + 1);
    }
    int __llpl_ret124 = 1;
    return __llpl_ret124;
}

int String_ends_with(String* self, char* suffix) {
    int64_t suffix_len = ((int64_t)llpl_strlen(suffix));
    if ((suffix_len > self->length)) {
        int __llpl_ret125 = 0;
        return __llpl_ret125;
    }
    int64_t offset = (self->length - suffix_len);
    int64_t i = 0;
    while ((i < suffix_len)) {
        if ((self->buf[(offset + i)] != suffix[i])) {
            int __llpl_ret126 = 0;
            return __llpl_ret126;
        }
        i = (i + 1);
    }
    int __llpl_ret127 = 1;
    return __llpl_ret127;
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
    String* __llpl_ret128 = String_new(out);
    return __llpl_ret128;
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
    String* __llpl_ret129 = String_new(out);
    return __llpl_ret129;
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
    String* __llpl_ret130 = String_byte_substring(self, start, (end - start));
    return __llpl_ret130;
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
    char* __llpl_ret131 = self->ptr;
    return __llpl_ret131;
}

uint64_t OwnedBuffer_len(OwnedBuffer* self) {
    uint64_t __llpl_ret132 = self->length;
    return __llpl_ret132;
}

int OwnedBuffer_is_null(OwnedBuffer* self) {
    int __llpl_ret133 = char_ptr_op_eq(self->ptr, NULL);
    return __llpl_ret133;
}

char OwnedBuffer_byte_at(OwnedBuffer* self, uint64_t index) {
    if ((index >= self->length)) {
        llpl_panic("OwnedBuffer.byte_at: index out of bounds");
    }
    char __llpl_ret134 = self->ptr[((int64_t)index)];
    return __llpl_ret134;
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
    Slice_char __llpl_ret135 = s;
    return __llpl_ret135;
}

char* OwnedBuffer_take(OwnedBuffer* self) {
    char* out = self->ptr;
    self->ptr = NULL;
    self->length = 0;
    char* __llpl_ret136 = out;
    return __llpl_ret136;
}


// Module: /home/nix/Claude/LLPL/stdlib/net/socket.llpl
const int64_t std_net_AF_INET = 2;

const int64_t std_net_AF_INET6 = 10;

const int64_t std_net_SOCK_STREAM = 1;

const int64_t std_net_SOCK_DGRAM = 2;

const int64_t std_net_SOCK_RAW = 3;

const int64_t std_net_IPPROTO_TCP = 6;

const int64_t std_net_IPPROTO_UDP = 17;

const int64_t std_net_IPPROTO_ICMP = 1;

const int64_t std_net_SOL_SOCKET = 1;

const int64_t std_net_SO_REUSEADDR = 2;

const int64_t std_net_SO_KEEPALIVE = 9;

const int64_t std_net_SO_RCVTIMEO = 20;

const int64_t std_net_SO_SNDTIMEO = 21;

const int64_t std_net_SHUT_RD = 0;

const int64_t std_net_SHUT_WR = 1;

const int64_t std_net_SHUT_RDWR = 2;

struct std_net_SockAddrIn {
    RefCount ref_count;
    uint16_t sin_family;
    uint16_t sin_port;
    uint32_t sin_addr;
    char sin_zero[8];
};

std_net_SockAddrIn* std_net_SockAddrIn_new() {
    std_net_SockAddrIn* self = (std_net_SockAddrIn*)rc_alloc(sizeof(std_net_SockAddrIn));
    if (!self) return NULL;
    rc_init(&self->ref_count);

    self->sin_family = ((uint16_t)std_net_AF_INET);
    self->sin_port = 0;
    self->sin_addr = 0;
    {
        int64_t i = 0;
        while ((i < 8)) {
            self->sin_zero[i] = 0;
            i = (i + 1);
        }
    }
    return self;
}

void std_net_SockAddrIn_set_port(std_net_SockAddrIn* self, uint16_t port) {
    self->sin_port = htons(port);
}

void std_net_SockAddrIn_set_addr(std_net_SockAddrIn* self, uint8_t a, uint8_t b, uint8_t c, uint8_t d) {
    uint32_t addr = (((((uint32_t)a) | (((uint32_t)b) << 8)) | (((uint32_t)c) << 16)) | (((uint32_t)d) << 24));
    self->sin_addr = addr;
}

void std_net_SockAddrIn_set_addr_any(std_net_SockAddrIn* self) {
    self->sin_addr = 0;
}

uint16_t std_net_SockAddrIn_get_port(std_net_SockAddrIn* self) {
    uint16_t __llpl_ret137 = ntohs(self->sin_port);
    return __llpl_ret137;
}


extern int64_t socket(int64_t domain, int64_t type, int64_t protocol);

extern int64_t bind(int64_t sockfd, void* addr, uint64_t addrlen);

extern int64_t listen(int64_t sockfd, int64_t backlog);

extern int64_t accept(int64_t sockfd, void* addr, uint64_t* addrlen);

extern int64_t connect(int64_t sockfd, void* addr, uint64_t addrlen);

extern int64_t send(int64_t sockfd, void* buf, uint64_t len, int64_t flags);

extern int64_t recv(int64_t sockfd, void* buf, uint64_t len, int64_t flags);

extern int64_t sendto(int64_t sockfd, void* buf, uint64_t len, int64_t flags, void* dest_addr, uint64_t addrlen);

extern int64_t recvfrom(int64_t sockfd, void* buf, uint64_t len, int64_t flags, void* src_addr, uint64_t* addrlen);

extern int64_t shutdown(int64_t sockfd, int64_t how);

extern int64_t close(int64_t fd);

extern int64_t setsockopt(int64_t sockfd, int64_t level, int64_t optname, void* optval, uint64_t optlen);

extern uint16_t htons(uint16_t hostshort);

extern uint16_t ntohs(uint16_t netshort);

extern uint32_t htonl(uint32_t hostlong);

extern uint32_t ntohl(uint32_t netlong);

struct std_net_Socket {
    RefCount ref_count;
    int64_t fd;
    int64_t domain;
    int64_t socket_type;
    int64_t protocol;
    int is_open;
};

std_net_Socket* std_net_Socket_new(int64_t dom, int64_t type, int64_t proto) {
    std_net_Socket* self = (std_net_Socket*)rc_alloc(sizeof(std_net_Socket));
    if (!self) return NULL;
    rc_init(&self->ref_count);

    self->domain = dom;
    self->socket_type = type;
    self->protocol = proto;
    self->fd = socket(dom, type, proto);
    self->is_open = (self->fd >= 0);
    return self;
}

void std_net_Socket_destroy(void* ptr) {
    std_net_Socket* self = (std_net_Socket*)ptr;
    if (self->is_open) {
        close(self->fd);
    }
}

int std_net_Socket_is_valid(std_net_Socket* self) {
    int __llpl_ret138 = self->is_open;
    return __llpl_ret138;
}

Result_bool_char_ptr* std_net_Socket_bind_addr(std_net_Socket* self, std_net_SockAddrIn* addr) {
    Result_bool_char_ptr* result = Result_bool_char_ptr_new();
    if (!self->is_open) {
        Result_bool_char_ptr_set_err(result, "Socket not open");
        Result_bool_char_ptr* __llpl_ret139 = result;
        return __llpl_ret139;
    }
    int64_t ret = bind(self->fd, ((void*)&addr), 16);
    if ((ret < 0)) {
        Result_bool_char_ptr_set_err(result, "Bind failed");
    } else {
        Result_bool_char_ptr_set_ok(result, 1);
    }
    Result_bool_char_ptr* __llpl_ret140 = result;
    return __llpl_ret140;
}

Result_bool_char_ptr* std_net_Socket_listen_backlog(std_net_Socket* self, int64_t backlog) {
    Result_bool_char_ptr* result = Result_bool_char_ptr_new();
    if (!self->is_open) {
        Result_bool_char_ptr_set_err(result, "Socket not open");
        Result_bool_char_ptr* __llpl_ret141 = result;
        return __llpl_ret141;
    }
    int64_t ret = listen(self->fd, backlog);
    if ((ret < 0)) {
        Result_bool_char_ptr_set_err(result, "Listen failed");
    } else {
        Result_bool_char_ptr_set_ok(result, 1);
    }
    Result_bool_char_ptr* __llpl_ret142 = result;
    return __llpl_ret142;
}

Result_std_net_Socket_char_ptr* std_net_Socket_accept_connection(std_net_Socket* self) {
    Result_std_net_Socket_char_ptr* result = Result_std_net_Socket_char_ptr_new();
    if (!self->is_open) {
        Result_std_net_Socket_char_ptr_set_err(result, "Socket not open");
        Result_std_net_Socket_char_ptr* __llpl_ret143 = result;
        return __llpl_ret143;
    }
    std_net_SockAddrIn* client_addr = std_net_SockAddrIn_new();
    uint64_t addrlen = 16;
    int64_t client_fd = accept(self->fd, ((void*)&client_addr), &addrlen);
    if ((client_fd < 0)) {
        Result_std_net_Socket_char_ptr_set_err(result, "Accept failed");
    } else {
        std_net_Socket* client_sock = std_net_Socket_new(self->domain, self->socket_type, self->protocol);
        close(client_sock->fd);
        client_sock->fd = client_fd;
        client_sock->is_open = 1;
        Result_std_net_Socket_char_ptr_set_ok(result, client_sock);
    }
    Result_std_net_Socket_char_ptr* __llpl_ret144 = result;
    return __llpl_ret144;
}

Result_bool_char_ptr* std_net_Socket_connect_to(std_net_Socket* self, std_net_SockAddrIn* addr) {
    Result_bool_char_ptr* result = Result_bool_char_ptr_new();
    if (!self->is_open) {
        Result_bool_char_ptr_set_err(result, "Socket not open");
        Result_bool_char_ptr* __llpl_ret145 = result;
        return __llpl_ret145;
    }
    int64_t ret = connect(self->fd, ((void*)&addr), 16);
    if ((ret < 0)) {
        Result_bool_char_ptr_set_err(result, "Connect failed");
    } else {
        Result_bool_char_ptr_set_ok(result, 1);
    }
    Result_bool_char_ptr* __llpl_ret146 = result;
    return __llpl_ret146;
}

Result_int_char_ptr* std_net_Socket_send_data(std_net_Socket* self, char* buffer, uint64_t size) {
    Result_int_char_ptr* result = Result_int_char_ptr_new();
    if (!self->is_open) {
        Result_int_char_ptr_set_err(result, "Socket not open");
        Result_int_char_ptr* __llpl_ret147 = result;
        return __llpl_ret147;
    }
    int64_t bytes_sent = send(self->fd, ((void*)buffer), size, 0);
    if ((bytes_sent < 0)) {
        Result_int_char_ptr_set_err(result, "Send failed");
    } else {
        Result_int_char_ptr_set_ok(result, bytes_sent);
    }
    Result_int_char_ptr* __llpl_ret148 = result;
    return __llpl_ret148;
}

Result_int_char_ptr* std_net_Socket_recv_data(std_net_Socket* self, char* buffer, uint64_t size) {
    Result_int_char_ptr* result = Result_int_char_ptr_new();
    if (!self->is_open) {
        Result_int_char_ptr_set_err(result, "Socket not open");
        Result_int_char_ptr* __llpl_ret149 = result;
        return __llpl_ret149;
    }
    int64_t bytes_recv = recv(self->fd, ((void*)buffer), size, 0);
    if ((bytes_recv < 0)) {
        Result_int_char_ptr_set_err(result, "Receive failed");
    } else {
        Result_int_char_ptr_set_ok(result, bytes_recv);
    }
    Result_int_char_ptr* __llpl_ret150 = result;
    return __llpl_ret150;
}

Result_int_char_ptr* std_net_Socket_send_string(std_net_Socket* self, String* s) {
    Result_int_char_ptr* __llpl_ret151 = std_net_Socket_send_data(self, String_c_str(s), ((uint64_t)String_length(s)));
    return __llpl_ret151;
}

Result_String_char_ptr* std_net_Socket_recv_string(std_net_Socket* self, uint64_t max_size) {
    Result_String_char_ptr* result = Result_String_char_ptr_new();
    char* buffer = ((char*)malloc((max_size + 1)));
    Result_int_char_ptr* recv_result = std_net_Socket_recv_data(self, buffer, max_size);
    if (!Result_int_char_ptr_is_ok(recv_result)) {
        free(((void*)buffer));
        Result_String_char_ptr_set_err(result, "Receive failed");
        Result_String_char_ptr* __llpl_ret152 = result;
        return __llpl_ret152;
    }
    int64_t bytes_recv = Result_int_char_ptr_unwrap(recv_result);
    buffer[bytes_recv] = 0;
    String* s = String_new(buffer);
    free(((void*)buffer));
    Result_String_char_ptr_set_ok(result, s);
    Result_String_char_ptr* __llpl_ret153 = result;
    return __llpl_ret153;
}

Result_bool_char_ptr* std_net_Socket_set_reuse_addr(std_net_Socket* self, int enable) {
    Result_bool_char_ptr* result = Result_bool_char_ptr_new();
    if (!self->is_open) {
        Result_bool_char_ptr_set_err(result, "Socket not open");
        Result_bool_char_ptr* __llpl_ret154 = result;
        return __llpl_ret154;
    }
    int64_t optval = ({ int64_t __llpl_ifexpr154; if (enable) { __llpl_ifexpr154 = 1; } else { __llpl_ifexpr154 = 0; } __llpl_ifexpr154; });
    int64_t ret = setsockopt(self->fd, std_net_SOL_SOCKET, std_net_SO_REUSEADDR, ((void*)&optval), 4);
    if ((ret < 0)) {
        Result_bool_char_ptr_set_err(result, "setsockopt failed");
    } else {
        Result_bool_char_ptr_set_ok(result, 1);
    }
    Result_bool_char_ptr* __llpl_ret156 = result;
    return __llpl_ret156;
}

Result_bool_char_ptr* std_net_Socket_shutdown_socket(std_net_Socket* self, int64_t how) {
    Result_bool_char_ptr* result = Result_bool_char_ptr_new();
    if (!self->is_open) {
        Result_bool_char_ptr_set_err(result, "Socket not open");
        Result_bool_char_ptr* __llpl_ret157 = result;
        return __llpl_ret157;
    }
    int64_t ret = shutdown(self->fd, how);
    if ((ret < 0)) {
        Result_bool_char_ptr_set_err(result, "Shutdown failed");
    } else {
        Result_bool_char_ptr_set_ok(result, 1);
    }
    Result_bool_char_ptr* __llpl_ret158 = result;
    return __llpl_ret158;
}


struct std_net_TcpServer {
    RefCount ref_count;
    std_net_Socket* socket;
    std_net_SockAddrIn* addr;
};

std_net_TcpServer* std_net_TcpServer_new(uint16_t port) {
    std_net_TcpServer* self = (std_net_TcpServer*)rc_alloc(sizeof(std_net_TcpServer));
    if (!self) return NULL;
    rc_init(&self->ref_count);

    socket = std_net_Socket_new(std_net_AF_INET, std_net_SOCK_STREAM, std_net_IPPROTO_TCP);
    self->addr = std_net_SockAddrIn_new();
    std_net_SockAddrIn_set_port(self->addr, port);
    std_net_SockAddrIn_set_addr_any(self->addr);
    return self;
}

Result_bool_char_ptr* std_net_TcpServer_start(std_net_TcpServer* self, int64_t backlog) {
    std_net_Socket_set_reuse_addr(socket, 1);
    Result_bool_char_ptr* bind_result = std_net_Socket_bind_addr(socket, self->addr);
    if (!Result_bool_char_ptr_is_ok(bind_result)) {
        Result_bool_char_ptr* __llpl_ret159 = bind_result;
        return __llpl_ret159;
    }
    Result_bool_char_ptr* __llpl_ret160 = std_net_Socket_listen_backlog(socket, backlog);
    return __llpl_ret160;
}

Result_std_net_Socket_char_ptr* std_net_TcpServer_accept(std_net_TcpServer* self) {
    Result_std_net_Socket_char_ptr* __llpl_ret161 = std_net_Socket_accept_connection(socket);
    return __llpl_ret161;
}

int std_net_TcpServer_is_valid(std_net_TcpServer* self) {
    int __llpl_ret162 = std_net_Socket_is_valid(socket);
    return __llpl_ret162;
}


struct std_net_TcpClient {
    RefCount ref_count;
    std_net_Socket* socket;
};

std_net_TcpClient* std_net_TcpClient_new() {
    std_net_TcpClient* self = (std_net_TcpClient*)rc_alloc(sizeof(std_net_TcpClient));
    if (!self) return NULL;
    rc_init(&self->ref_count);

    socket = std_net_Socket_new(std_net_AF_INET, std_net_SOCK_STREAM, std_net_IPPROTO_TCP);
    return self;
}

Result_bool_char_ptr* std_net_TcpClient_connect(std_net_TcpClient* self, uint8_t host_a, uint8_t host_b, uint8_t host_c, uint8_t host_d, uint16_t port) {
    std_net_SockAddrIn* addr = std_net_SockAddrIn_new();
    std_net_SockAddrIn_set_port(addr, port);
    std_net_SockAddrIn_set_addr(addr, host_a, host_b, host_c, host_d);
    Result_bool_char_ptr* __llpl_ret163 = std_net_Socket_connect_to(socket, addr);
    return __llpl_ret163;
}

Result_int_char_ptr* std_net_TcpClient_send(std_net_TcpClient* self, String* data) {
    Result_int_char_ptr* __llpl_ret164 = std_net_Socket_send_string(socket, data);
    return __llpl_ret164;
}

Result_String_char_ptr* std_net_TcpClient_recv(std_net_TcpClient* self, uint64_t max_size) {
    Result_String_char_ptr* __llpl_ret165 = std_net_Socket_recv_string(socket, max_size);
    return __llpl_ret165;
}

int std_net_TcpClient_is_valid(std_net_TcpClient* self) {
    int __llpl_ret166 = std_net_Socket_is_valid(socket);
    return __llpl_ret166;
}

void std_net_TcpClient_close(std_net_TcpClient* self) {
    std_net_Socket_shutdown_socket(socket, std_net_SHUT_RDWR);
}


struct std_net_UdpSocket {
    RefCount ref_count;
    std_net_Socket* socket;
    std_net_SockAddrIn* addr;
};

std_net_UdpSocket* std_net_UdpSocket_new(uint16_t port) {
    std_net_UdpSocket* self = (std_net_UdpSocket*)rc_alloc(sizeof(std_net_UdpSocket));
    if (!self) return NULL;
    rc_init(&self->ref_count);

    socket = std_net_Socket_new(std_net_AF_INET, std_net_SOCK_DGRAM, std_net_IPPROTO_UDP);
    self->addr = std_net_SockAddrIn_new();
    std_net_SockAddrIn_set_port(self->addr, port);
    std_net_SockAddrIn_set_addr_any(self->addr);
    return self;
}

Result_bool_char_ptr* std_net_UdpSocket_bind_socket(std_net_UdpSocket* self) {
    Result_bool_char_ptr* __llpl_ret167 = std_net_Socket_bind_addr(socket, self->addr);
    return __llpl_ret167;
}

Result_int_char_ptr* std_net_UdpSocket_send_to(std_net_UdpSocket* self, char* data, uint64_t size, std_net_SockAddrIn* dest_addr) {
    Result_int_char_ptr* result = Result_int_char_ptr_new();
    if (!std_net_Socket_is_valid(socket)) {
        Result_int_char_ptr_set_err(result, "Socket not open");
        Result_int_char_ptr* __llpl_ret168 = result;
        return __llpl_ret168;
    }
    int64_t bytes_sent = sendto(socket->fd, ((void*)data), size, 0, ((void*)&dest_addr), 16);
    if ((bytes_sent < 0)) {
        Result_int_char_ptr_set_err(result, "Send failed");
    } else {
        Result_int_char_ptr_set_ok(result, bytes_sent);
    }
    Result_int_char_ptr* __llpl_ret169 = result;
    return __llpl_ret169;
}

Result_int_char_ptr* std_net_UdpSocket_recv_from(std_net_UdpSocket* self, char* buffer, uint64_t size) {
    Result_int_char_ptr* result = Result_int_char_ptr_new();
    if (!std_net_Socket_is_valid(socket)) {
        Result_int_char_ptr_set_err(result, "Socket not open");
        Result_int_char_ptr* __llpl_ret170 = result;
        return __llpl_ret170;
    }
    std_net_SockAddrIn* src_addr = std_net_SockAddrIn_new();
    uint64_t addrlen = 16;
    int64_t bytes_recv = recvfrom(socket->fd, ((void*)buffer), size, 0, ((void*)&src_addr), &addrlen);
    if ((bytes_recv < 0)) {
        Result_int_char_ptr_set_err(result, "Receive failed");
    } else {
        Result_int_char_ptr_set_ok(result, bytes_recv);
    }
    Result_int_char_ptr* __llpl_ret171 = result;
    return __llpl_ret171;
}

int std_net_UdpSocket_is_valid(std_net_UdpSocket* self) {
    int __llpl_ret172 = std_net_Socket_is_valid(socket);
    return __llpl_ret172;
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
    { "int_equals", (void*)int_equals, "?", 1233 },
    { "uint_hash", (void*)uint_hash, "?", 1239 },
    { "char_ptr_equals", (void*)char_ptr_equals, "?", 1272 },
    { "char_ptr_op_ne", (void*)char_ptr_op_ne, "?", 1350 },
    { "char_ptr_op_lt", (void*)char_ptr_op_lt, "?", 1354 },
    { "char_ptr_hash", (void*)char_ptr_hash, "?", 1261 },
    { "char_equals", (void*)char_equals, "?", 1251 },
    { "char_ptr_op_ge", (void*)char_ptr_op_ge, "?", 1376 },
    { "int_hash", (void*)int_hash, "?", 1230 },
    { "char_ptr_op_gt", (void*)char_ptr_op_gt, "?", 1363 },
    { "char_hash", (void*)char_hash, "?", 1248 },
    { "uint_compare", (void*)uint_compare, "?", 1313 },
    { "char_ptr_op_eq", (void*)char_ptr_op_eq, "?", 1341 },
    { "char_ptr_op_le", (void*)char_ptr_op_le, "?", 1372 },
    { "String_hash", (void*)String_hash, "?", 1280 },
    { "String_equals", (void*)String_equals, "?", 1290 },
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
    { "std_net_UdpSocket_new", (void*)std_net_UdpSocket_new, "socket.llpl", 359 },
    { "std_net_UdpSocket_bind_socket", (void*)std_net_UdpSocket_bind_socket, "socket.llpl", 366 },
    { "std_net_UdpSocket_send_to", (void*)std_net_UdpSocket_send_to, "socket.llpl", 370 },
    { "std_net_UdpSocket_recv_from", (void*)std_net_UdpSocket_recv_from, "socket.llpl", 388 },
    { "std_net_UdpSocket_is_valid", (void*)std_net_UdpSocket_is_valid, "socket.llpl", 409 },
    { "Result_Socket_char_ptr_new", (void*)Result_Socket_char_ptr_new, "?", 1083 },
    { "Result_Socket_char_ptr_set_ok", (void*)Result_Socket_char_ptr_set_ok, "?", 1090 },
    { "Result_Socket_char_ptr_set_err", (void*)Result_Socket_char_ptr_set_err, "?", 1095 },
    { "Result_Socket_char_ptr_set_err_with_trace", (void*)Result_Socket_char_ptr_set_err_with_trace, "?", 1103 },
    { "Result_Socket_char_ptr_get_ok", (void*)Result_Socket_char_ptr_get_ok, "?", 1112 },
    { "Result_Socket_char_ptr_get_err", (void*)Result_Socket_char_ptr_get_err, "?", 1116 },
    { "Result_Socket_char_ptr_get_trace", (void*)Result_Socket_char_ptr_get_trace, "?", 1120 },
    { "Result_Socket_char_ptr_is_ok", (void*)Result_Socket_char_ptr_is_ok, "?", 1124 },
    { "Result_Socket_char_ptr_is_err", (void*)Result_Socket_char_ptr_is_err, "?", 1128 },
    { "Result_std_net_Socket_char_ptr_new", (void*)Result_std_net_Socket_char_ptr_new, "?", 1083 },
    { "Result_std_net_Socket_char_ptr_set_ok", (void*)Result_std_net_Socket_char_ptr_set_ok, "?", 1090 },
    { "Result_std_net_Socket_char_ptr_set_err", (void*)Result_std_net_Socket_char_ptr_set_err, "?", 1095 },
    { "Result_std_net_Socket_char_ptr_set_err_with_trace", (void*)Result_std_net_Socket_char_ptr_set_err_with_trace, "?", 1103 },
    { "Result_std_net_Socket_char_ptr_get_ok", (void*)Result_std_net_Socket_char_ptr_get_ok, "?", 1112 },
    { "Result_std_net_Socket_char_ptr_get_err", (void*)Result_std_net_Socket_char_ptr_get_err, "?", 1116 },
    { "Result_std_net_Socket_char_ptr_get_trace", (void*)Result_std_net_Socket_char_ptr_get_trace, "?", 1120 },
    { "Result_std_net_Socket_char_ptr_is_ok", (void*)Result_std_net_Socket_char_ptr_is_ok, "?", 1124 },
    { "Result_std_net_Socket_char_ptr_is_err", (void*)Result_std_net_Socket_char_ptr_is_err, "?", 1128 },
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
    { "std_net_SockAddrIn_new", (void*)std_net_SockAddrIn_new, "socket.llpl", 40 },
    { "std_net_SockAddrIn_set_port", (void*)std_net_SockAddrIn_set_port, "socket.llpl", 49 },
    { "std_net_SockAddrIn_set_addr", (void*)std_net_SockAddrIn_set_addr, "socket.llpl", 53 },
    { "std_net_SockAddrIn_set_addr_any", (void*)std_net_SockAddrIn_set_addr_any, "socket.llpl", 58 },
    { "std_net_SockAddrIn_get_port", (void*)std_net_SockAddrIn_get_port, "socket.llpl", 62 },
    { "std_net_TcpClient_new", (void*)std_net_TcpClient_new, "socket.llpl", 326 },
    { "std_net_TcpClient_connect", (void*)std_net_TcpClient_connect, "socket.llpl", 330 },
    { "std_net_TcpClient_send", (void*)std_net_TcpClient_send, "socket.llpl", 337 },
    { "std_net_TcpClient_recv", (void*)std_net_TcpClient_recv, "socket.llpl", 341 },
    { "std_net_TcpClient_is_valid", (void*)std_net_TcpClient_is_valid, "socket.llpl", 345 },
    { "std_net_TcpClient_close", (void*)std_net_TcpClient_close, "socket.llpl", 349 },
    { "ReflectField_new", (void*)ReflectField_new, "prelude.llpl", 90 },
    { "ReflectField_exists", (void*)ReflectField_exists, "prelude.llpl", 96 },
    { "ReflectField_name", (void*)ReflectField_name, "prelude.llpl", 100 },
    { "ReflectField_type_name", (void*)ReflectField_type_name, "prelude.llpl", 104 },
    { "ReflectField_offset", (void*)ReflectField_offset, "prelude.llpl", 108 },
    { "ReflectField_size", (void*)ReflectField_size, "prelude.llpl", 112 },
    { "std_net_Socket_new", (void*)std_net_Socket_new, "socket.llpl", 93 },
    { "std_net_Socket_is_valid", (void*)std_net_Socket_is_valid, "socket.llpl", 107 },
    { "std_net_Socket_bind_addr", (void*)std_net_Socket_bind_addr, "socket.llpl", 111 },
    { "std_net_Socket_listen_backlog", (void*)std_net_Socket_listen_backlog, "socket.llpl", 129 },
    { "std_net_Socket_accept_connection", (void*)std_net_Socket_accept_connection, "socket.llpl", 147 },
    { "std_net_Socket_connect_to", (void*)std_net_Socket_connect_to, "socket.llpl", 172 },
    { "std_net_Socket_send_data", (void*)std_net_Socket_send_data, "socket.llpl", 190 },
    { "std_net_Socket_recv_data", (void*)std_net_Socket_recv_data, "socket.llpl", 208 },
    { "std_net_Socket_send_string", (void*)std_net_Socket_send_string, "socket.llpl", 226 },
    { "std_net_Socket_recv_string", (void*)std_net_Socket_recv_string, "socket.llpl", 230 },
    { "std_net_Socket_set_reuse_addr", (void*)std_net_Socket_set_reuse_addr, "socket.llpl", 251 },
    { "std_net_Socket_shutdown_socket", (void*)std_net_Socket_shutdown_socket, "socket.llpl", 271 },
    { "Result_int_char_ptr_new", (void*)Result_int_char_ptr_new, "?", 1083 },
    { "Result_int_char_ptr_set_ok", (void*)Result_int_char_ptr_set_ok, "?", 1090 },
    { "Result_int_char_ptr_set_err", (void*)Result_int_char_ptr_set_err, "?", 1095 },
    { "Result_int_char_ptr_set_err_with_trace", (void*)Result_int_char_ptr_set_err_with_trace, "?", 1103 },
    { "Result_int_char_ptr_get_ok", (void*)Result_int_char_ptr_get_ok, "?", 1112 },
    { "Result_int_char_ptr_get_err", (void*)Result_int_char_ptr_get_err, "?", 1116 },
    { "Result_int_char_ptr_get_trace", (void*)Result_int_char_ptr_get_trace, "?", 1120 },
    { "Result_int_char_ptr_is_ok", (void*)Result_int_char_ptr_is_ok, "?", 1124 },
    { "Result_int_char_ptr_is_err", (void*)Result_int_char_ptr_is_err, "?", 1128 },
    { "std_net_TcpServer_new", (void*)std_net_TcpServer_new, "socket.llpl", 295 },
    { "std_net_TcpServer_start", (void*)std_net_TcpServer_start, "socket.llpl", 302 },
    { "std_net_TcpServer_accept", (void*)std_net_TcpServer_accept, "socket.llpl", 313 },
    { "std_net_TcpServer_is_valid", (void*)std_net_TcpServer_is_valid, "socket.llpl", 317 },
    { "RegexMatch_new", (void*)RegexMatch_new, "prelude.llpl", 170 },
    { "RegexMatch_is_match", (void*)RegexMatch_is_match, "prelude.llpl", 188 },
    { "RegexMatch_group_count", (void*)RegexMatch_group_count, "prelude.llpl", 192 },
    { "RegexMatch_has_group", (void*)RegexMatch_has_group, "prelude.llpl", 196 },
    { "RegexMatch_group_start", (void*)RegexMatch_group_start, "prelude.llpl", 205 },
    { "RegexMatch_group_end", (void*)RegexMatch_group_end, "prelude.llpl", 217 },
    { "RegexMatch_group", (void*)RegexMatch_group, "prelude.llpl", 229 },
    { "RegexMatch_expand", (void*)RegexMatch_expand, "prelude.llpl", 244 },
    { "Result_bool_char_ptr_new", (void*)Result_bool_char_ptr_new, "?", 1083 },
    { "Result_bool_char_ptr_set_ok", (void*)Result_bool_char_ptr_set_ok, "?", 1090 },
    { "Result_bool_char_ptr_set_err", (void*)Result_bool_char_ptr_set_err, "?", 1095 },
    { "Result_bool_char_ptr_set_err_with_trace", (void*)Result_bool_char_ptr_set_err_with_trace, "?", 1103 },
    { "Result_bool_char_ptr_get_ok", (void*)Result_bool_char_ptr_get_ok, "?", 1112 },
    { "Result_bool_char_ptr_get_err", (void*)Result_bool_char_ptr_get_err, "?", 1116 },
    { "Result_bool_char_ptr_get_trace", (void*)Result_bool_char_ptr_get_trace, "?", 1120 },
    { "Result_bool_char_ptr_is_ok", (void*)Result_bool_char_ptr_is_ok, "?", 1124 },
    { "Result_bool_char_ptr_is_err", (void*)Result_bool_char_ptr_is_err, "?", 1128 },
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
uint64_t llpl_symbol_table_count = 168;


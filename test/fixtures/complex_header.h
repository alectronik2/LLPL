#define ignored_macro(x) ((x) + 1)

/* block comment with a fake prototype:
int hidden(int nope);
*/
extern const char *name_of(unsigned long id);
static inline void consume_buffer(const uint8_t data[16], size_t len);
int log_msg(const char *fmt, ...);
struct Device {
    uint64_t id;
    const char *name;
    uint8_t mac[6];
};
struct Device *device_open(const char *path);
typedef int (*callback_t)(int value);
callback_t make_callback(void);
uint64_t read64(volatile void *addr);
__attribute__((unused)) unsigned short attr_demo(unsigned int value);

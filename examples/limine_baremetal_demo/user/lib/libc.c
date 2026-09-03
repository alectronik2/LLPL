#include "llpl_sys.h"
#include <stddef.h>
#include <stdarg.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <ctype.h>
#include <errno.h>
#include <time.h>
#include <locale.h>
#include <signal.h>
#include <math.h>

int errno;

void *memcpy(void *d, const void *s, size_t n) { unsigned char *a=d; const unsigned char *b=s; while(n--) *a++=*b++; return d; }
void *memmove(void *d, const void *s, size_t n) { unsigned char *a=d; const unsigned char *b=s; if(a<b) return memcpy(d,s,n); while(n--) a[n]=b[n]; return d; }
void *memset(void *d, int c, size_t n) { unsigned char *a=d; while(n--) *a++=(unsigned char)c; return d; }
void *memchr(const void *s,int c,size_t n){const unsigned char*p=s;while(n--){if(*p==(unsigned char)c)return(void*)p;p++;}return 0;}
int memcmp(const void *a, const void *b, size_t n) { const unsigned char *x=a,*y=b; while(n--) { if(*x!=*y) return *x-*y; x++; y++; } return 0; }
size_t strlen(const char *s) { const char *p=s; while(*p) p++; return (size_t)(p-s); }
size_t strnlen(const char *s,size_t n) { size_t i=0; while(i<n&&s[i]) i++; return i; }
char *strcpy(char *d,const char *s) { char *r=d; while((*d++=*s++)); return r; }
char *strncpy(char *d,const char *s,size_t n) { char *r=d; while(n&&*s){*d++=*s++;n--;} while(n--)*d++=0; return r; }
char *strcat(char *d,const char *s) { strcpy(d+strlen(d),s); return d; }
int strcmp(const char*a,const char*b){while(*a&&*a==*b){a++;b++;}return (unsigned char)*a-(unsigned char)*b;}
int strncmp(const char*a,const char*b,size_t n){while(n&&*a&&*a==*b){a++;b++;n--;}return n?((unsigned char)*a-(unsigned char)*b):0;}
int strcoll(const char*a,const char*b){return strcmp(a,b);}
char *strchr(const char*s,int c){do{if(*s==(char)c)return(char*)s;}while(*s++);return 0;}
char *strrchr(const char*s,int c){const char*r=0;do{if(*s==(char)c)r=s;}while(*s++);return(char*)r;}
char *strstr(const char*h,const char*n){size_t z=strlen(n);if(!z)return(char*)h;for(;*h;h++)if(!memcmp(h,n,z))return(char*)h;return 0;}
char *strpbrk(const char*s,const char*a){for(;*s;s++)if(strchr(a,*s))return(char*)s;return 0;} size_t strspn(const char*s,const char*a){size_t n=0;while(s[n]&&strchr(a,s[n]))n++;return n;}
char *strerror(int e){(void)e;return(char*)"system error";}

int isalpha(int c){return(c>='a'&&c<='z')||(c>='A'&&c<='Z');} int isdigit(int c){return c>='0'&&c<='9';}
int isalnum(int c){return isalpha(c)||isdigit(c);} int isspace(int c){return c==' '||(c>='\t'&&c<='\r');}
int iscntrl(int c){return(c>=0&&c<32)||c==127;} int isgraph(int c){return c>32&&c<127;}
int islower(int c){return c>='a'&&c<='z';} int isupper(int c){return c>='A'&&c<='Z';}
int isprint(int c){return c>=32&&c<127;} int ispunct(int c){return isgraph(c)&&!isalnum(c);}
int isxdigit(int c){return isdigit(c)||(c>='a'&&c<='f')||(c>='A'&&c<='F');}
int tolower(int c){return isupper(c)?c+('a'-'A'):c;} int toupper(int c){return islower(c)?c-('a'-'A'):c;}

static int digit(int c){if(c>='0'&&c<='9')return c-'0';c=tolower(c);return c>='a'&&c<='z'?c-'a'+10:-1;}
unsigned long strtoul(const char*s,char**end,int base){while(isspace(*s))s++;int neg=*s=='-';if(*s=='-'||*s=='+')s++;if(!base){base=10;if(s[0]=='0'){base=8;if(tolower(s[1])=='x'){base=16;s+=2;}}}else if(base==16&&s[0]=='0'&&tolower(s[1])=='x')s+=2;unsigned long v=0;const char*start=s;int d;while((d=digit(*s))>=0&&d<base){v=v*(unsigned)base+(unsigned)d;s++;}if(end)*end=(char*)(s==start?start:s);return neg?(unsigned long)(-(long)v):v;}
long strtol(const char*s,char**e,int b){return(long)strtoul(s,e,b);} int atoi(const char*s){return(int)strtol(s,0,10);}
int abs(int x){return x<0?-x:x;}
double strtod(const char*s,char**end){while(isspace(*s))s++;int neg=*s=='-';if(*s=='-'||*s=='+')s++;const char*start=s;double v=0.0;while(isdigit(*s))v=v*10.0+(*s++-'0');if(*s=='.'){double p=.1;s++;while(isdigit(*s)){v+=(*s++-'0')*p;p*=.1;}}if(tolower(*s)=='e'){const char*ep=s++;int eneg=*s=='-';if(*s=='-'||*s=='+')s++;if(!isdigit(*s))s=ep;else{int e=0;while(isdigit(*s))e=e*10+(*s++-'0');double p=1.0;while(e--)p*=10.0;v=eneg?v/p:v*p;}}if(end)*end=(char*)(s==start?start:s);return neg?-v:v;}

void exit(int status){call2(SYS_EXIT,(u64)(long)status,0);for(;;)__asm__ volatile("pause");}
void abort(void){exit(134);}

__asm__(
".global setjmp\nsetjmp:\n"
"movq %rbx,0(%rdi);movq %rbp,8(%rdi);movq %r12,16(%rdi);movq %r13,24(%rdi);movq %r14,32(%rdi);movq %r15,40(%rdi);"
"leaq 8(%rsp),%rax;movq %rax,48(%rdi);movq (%rsp),%rax;movq %rax,56(%rdi);xorl %eax,%eax;ret\n"
".global longjmp\nlongjmp:\n"
"movq 0(%rdi),%rbx;movq 8(%rdi),%rbp;movq 16(%rdi),%r12;movq 24(%rdi),%r13;movq 32(%rdi),%r14;movq 40(%rdi),%r15;"
"movq 48(%rdi),%rsp;movq 56(%rdi),%rdx;movl %esi,%eax;testl %eax,%eax;jnz 1f;incl %eax;1:jmp *%rdx\n");

#define F_READ 1
#define F_WRITE 2
#define F_STATIC 4
static FILE std_in={-1,F_READ|F_STATIC,0,0,-1},std_out={1,F_WRITE|F_STATIC,0,0,-1},std_err={2,F_WRITE|F_STATIC,0,0,-1};
FILE *stdin=&std_in,*stdout=&std_out,*stderr=&std_err;
static int ensure_input(FILE*f){if(f==stdin&&f->fd<0)f->fd=(long)call2(SYS_OPEN,(u64)"/dev/kbd",1);return f->fd>=0;}
FILE *fopen(const char*p,const char*m){unsigned k=0,fl=0;if(*m=='r'){k=1;fl=F_READ;}else if(*m=='w'){k=2|4|8;fl=F_WRITE;}else if(*m=='a'){k=2|4;fl=F_WRITE;}else{return 0;}if(m[1]=='+'||(m[1]=='b'&&m[2]=='+')){k|=1|2;fl|=F_READ|F_WRITE;}long fd=(long)call2(SYS_OPEN,(u64)p,k);if(fd<0){errno=ENOENT;return 0;}FILE*f=malloc(sizeof* f);if(!f){call2(SYS_CLOSE,fd,0);errno=ENOMEM;return 0;}f->fd=fd;f->flags=fl;f->error=f->eof=0;f->ungot=-1;if(*m=='a')call3(SYS_SEEK,fd,0,SEEK_END);return f;}
int fclose(FILE*f){if(!f||f->flags&F_STATIC)return EOF;int r=(long)call2(SYS_CLOSE,f->fd,0)<0?EOF:0;free(f);return r;}
size_t fread(void*p,size_t z,size_t n,FILE*f){if(!z||!n)return 0;if(!f||!(f->flags&F_READ)||!ensure_input(f)){if(f)f->error=1;return 0;}size_t total=z*n;long r=(long)call3(SYS_FD_READ,f->fd,(u64)p,total);if(r<0){f->error=1;return 0;}if(!r)f->eof=1;return(size_t)r/z;}
size_t fwrite(const void*p,size_t z,size_t n,FILE*f){if(!z||!n)return 0;if(!f||!(f->flags&F_WRITE))return 0;size_t total=z*n;long r;if(f==stdout||f==stderr){call2(SYS_WRITE,total,(u64)p);r=(long)total;}else r=(long)call3(SYS_FD_WRITE,f->fd,(u64)p,total);if(r<0){f->error=1;return 0;}return(size_t)r/z;}
int fseek(FILE*f,long o,int w){if(!f||f->flags&F_STATIC)return EOF;long r=(long)call3(SYS_SEEK,f->fd,(u64)o,w);if(r<0){f->error=1;return EOF;}f->eof=0;return 0;}
long ftell(FILE*f){return(!f||f->flags&F_STATIC)?-1:(long)call3(SYS_SEEK,f->fd,0,SEEK_CUR);}
int fflush(FILE*f){(void)f;return 0;} int feof(FILE*f){return f?f->eof:0;} int ferror(FILE*f){return f?f->error:1;} void clearerr(FILE*f){if(f)f->error=f->eof=0;}
int fgetc(FILE*f){if(f&&f->ungot>=0){int c=f->ungot;f->ungot=-1;return c;}unsigned char c;return fread(&c,1,1,f)==1?c:EOF;} int getc(FILE*f){return fgetc(f);} char*fgets(char*s,int n,FILE*f){if(n<=0)return 0;int i=0,c;while(i<n-1&&(c=fgetc(f))!=EOF){s[i++]=(char)c;if(c=='\n')break;}s[i]=0;return i?s:0;}
int fputc(int c,FILE*f){unsigned char x=(unsigned char)c;return fwrite(&x,1,1,f)==1?x:EOF;} int fputs(const char*s,FILE*f){return fwrite(s,1,strlen(s),f)?0:EOF;}
int ungetc(int c,FILE*f){if(!f||c==EOF||f->ungot>=0)return EOF;f->ungot=(unsigned char)c;f->eof=0;return c;} FILE *freopen(const char*p,const char*m,FILE*f){(void)f;return fopen(p,m);} FILE *tmpfile(void){errno=EINVAL;return 0;} int setvbuf(FILE*f,char*b,int m,size_t z){(void)f;(void)b;(void)m;(void)z;return 0;}
char *tmpnam(char*s){(void)s;errno=EINVAL;return 0;}
int remove(const char*p){(void)p;errno=EINVAL;return-1;} int rename(const char*a,const char*b){(void)a;(void)b;errno=EINVAL;return-1;}

static void outc(char*b,size_t n,size_t*p,char c){if(*p+1<n)b[*p]=c;(*p)++;}
static void outs(char*b,size_t n,size_t*p,const char*s){while(*s)outc(b,n,p,*s++);}
static void outu(char*b,size_t n,size_t*p,unsigned long v,unsigned base){char t[32];int i=0;do{unsigned d=v%base;t[i++]=(char)(d<10?'0'+d:'a'+d-10);v/=base;}while(v);while(i)outc(b,n,p,t[--i]);}
int vsnprintf(char*b,size_t n,const char*f,va_list ap){size_t p=0;while(*f){if(*f!='%'){outc(b,n,&p,*f++);continue;}f++;if(*f=='%'){outc(b,n,&p,*f++);continue;}int prec=6;if(*f=='.'){f++;prec=0;if(*f=='*'){prec=va_arg(ap,int);f++;}else while(isdigit(*f))prec=prec*10+(*f++-'0');}int lm=0;while(*f=='l'||*f=='z'){if(*f=='l')lm=1;f++;}char c=*f++;if(c=='s')outs(b,n,&p,va_arg(ap,char*));else if(c=='c')outc(b,n,&p,(char)va_arg(ap,int));else if(c=='d'||c=='i'){long v=lm?va_arg(ap,long):(long)va_arg(ap,int);if(v<0){outc(b,n,&p,'-');v=-v;}outu(b,n,&p,(unsigned long)v,10);}else if(c=='u')outu(b,n,&p,lm?va_arg(ap,unsigned long):(unsigned long)va_arg(ap,unsigned int),10);else if(c=='x'||c=='X')outu(b,n,&p,lm?va_arg(ap,unsigned long):(unsigned long)va_arg(ap,unsigned int),16);else if(c=='p')outu(b,n,&p,(unsigned long)va_arg(ap,void*),16);else if(c=='f'||c=='g'){double v=va_arg(ap,double);if(v<0){outc(b,n,&p,'-');v=-v;}unsigned q=(unsigned)v;outu(b,n,&p,q,10);if(prec){outc(b,n,&p,'.');v-=(double)q;for(int i=0;i<prec;i++){v*=10.0;int d=(int)v;outc(b,n,&p,(char)('0'+d));v-=d;}}}else{outc(b,n,&p,'%');outc(b,n,&p,c);}}if(n)b[p<n?p:n-1]=0;return(int)p;}
int snprintf(char*b,size_t n,const char*f,...){va_list a;va_start(a,f);int r=vsnprintf(b,n,f,a);va_end(a);return r;}
int sprintf(char*b,const char*f,...){va_list a;va_start(a,f);int r=vsnprintf(b,(size_t)-1,f,a);va_end(a);return r;}
int fprintf(FILE*o,const char*f,...){char b[1024];va_list a;va_start(a,f);int r=vsnprintf(b,sizeof b,f,a);va_end(a);fwrite(b,1,(size_t)(r<1023?r:1023),o);return r;}
int printf(const char*f,...){char b[1024];va_list a;va_start(a,f);int r=vsnprintf(b,sizeof b,f,a);va_end(a);fwrite(b,1,(size_t)(r<1023?r:1023),stdout);return r;}

time_t time(time_t*t){time_t v=(time_t)call2(64,0,0);if(t)*t=v;return v;} clock_t clock(void){return(clock_t)call2(SYS_MONOTONIC_MS,0,0);}
char *setlocale(int c,const char*s){(void)c;return(!s||!strcmp(s,"C")||!strcmp(s,""))?(char*)"C":0;} struct lconv *localeconv(void){static struct lconv l={(char*)"."};return&l;}
char *getenv(const char*n){(void)n;return 0;} int system(const char*c){(void)c;return -1;}
sighandler_t signal(int s,sighandler_t h){(void)s;return h;}
double difftime(time_t a,time_t b){return(double)(a-b);} time_t mktime(struct tm*t){(void)t;return(time_t)-1;} struct tm *localtime(const time_t*t){(void)t;return 0;} struct tm *gmtime(const time_t*t){(void)t;return 0;} size_t strftime(char*b,size_t n,const char*f,const struct tm*t){(void)b;(void)n;(void)f;(void)t;return 0;}

double fabs(double x){return x<0?-x:x;}
long fp_trunc(double);
double fp_from_long(long);
__asm__(".global fp_trunc\nfp_trunc:.byte 0xf2,0x48,0x0f,0x2c,0xc0\nret\n"
        ".global fp_from_long\nfp_from_long:.byte 0xf2,0x48,0x0f,0x2a,0xc7\nret\n");
double floor(double x){long i=fp_trunc(x);double d=fp_from_long(i);return d>x?fp_from_long(i-1):d;}
double ceil(double x){long i=fp_trunc(x);double d=fp_from_long(i);return d<x?fp_from_long(i+1):d;}
double fmod(double x,double y){long q=fp_trunc(x/y);return x-fp_from_long(q)*y;}
double modf(double x,double*i){*i=x<0?ceil(x):floor(x);return x-*i;}
__asm__(".global sqrt\nsqrt:.byte 0xf2,0x0f,0x51,0xc0\nret\n");
double frexp(double x,int*e){if(x==0){*e=0;return 0;}int n=0;double a=fabs(x);while(a>=1){a*=.5;n++;}while(a<.5){a*=2;n--;}*e=n;return x<0?-a:a;}
double ldexp(double x,int e){while(e>0){x*=2;e--;}while(e<0){x*=.5;e++;}return x;}
double log(double x){if(x<=0)return -HUGE_VAL;int e;double m=frexp(x,&e);double z=(m-0.75)/(m+0.75),z2=z*z,s=z,term=z;for(int k=3;k<30;k+=2){term*=z2;s+=term/k;}return 2*s+e*0.6931471805599453;}
double log2(double x){return log(x)*1.4426950408889634;} double log10(double x){return log(x)*0.4342944819032518;}
double exp(double x){int e=0;while(x>0.5){x-=0.6931471805599453;e++;}while(x<-.5){x+=0.6931471805599453;e--;}double s=1,term=1;for(int k=1;k<24;k++){term*=x/k;s+=term;}return ldexp(s,e);}
double pow(double x,double y){if(x==0)return y==0?1:0;if(x<0){long i=fp_trunc(y);if(fp_from_long(i)!=y)return NAN;double r=exp(y*log(-x));return(i&1)?-r:r;}return exp(y*log(x));}
__asm__(".global sin\nsin:.byte 0x48,0x83,0xec,0x08,0xf2,0x0f,0x11,0x04,0x24,0xdd,0x04,0x24,0xd9,0xfe,0xdd,0x1c,0x24,0xf2,0x0f,0x10,0x04,0x24,0x48,0x83,0xc4,0x08,0xc3\n"
        ".global cos\ncos:.byte 0x48,0x83,0xec,0x08,0xf2,0x0f,0x11,0x04,0x24,0xdd,0x04,0x24,0xd9,0xff,0xdd,0x1c,0x24,0xf2,0x0f,0x10,0x04,0x24,0x48,0x83,0xc4,0x08,0xc3\n"
        ".global tan\ntan:.byte 0x48,0x83,0xec,0x08,0xf2,0x0f,0x11,0x04,0x24,0xdd,0x04,0x24,0xd9,0xf2,0xdd,0xd8,0xdd,0x1c,0x24,0xf2,0x0f,0x10,0x04,0x24,0x48,0x83,0xc4,0x08,0xc3\n"
        ".global atan2\natan2:.byte 0x48,0x83,0xec,0x10,0xf2,0x0f,0x11,0x04,0x24,0xf2,0x0f,0x11,0x4c,0x24,0x08,0xdd,0x04,0x24,0xdd,0x44,0x24,0x08,0xd9,0xf3,0xdd,0x1c,0x24,0xf2,0x0f,0x10,0x04,0x24,0x48,0x83,0xc4,0x10,0xc3\n");
double atan(double x){return atan2(x,1.0);} double asin(double x){return atan2(x,sqrt(1-x*x));} double acos(double x){return atan2(sqrt(1-x*x),x);}

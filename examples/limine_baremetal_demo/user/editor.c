#include "lib/llpl_sys.h"
#include <string.h>

#define CAPACITY 16384
#define VIEW_ROWS 22
#define PATH_SIZE 128

enum { O_READ=1, O_WRITE=2, O_CREATE=4, O_TRUNC=8 };
static char text[CAPACITY];
static u64 length, cursor, scroll_line;
static char path[PATH_SIZE];
static int dirty;
static int existing_file;

static int alpha(char c) { return (c>='a'&&c<='z')||(c>='A'&&c<='Z')||c=='_'; }
static int alnum(char c) { return alpha(c)||(c>='0'&&c<='9'); }
static int keyword(const char *s,u64 n) {
    static const char *words[]={"and","break","do","else","elseif","end","false","for","function","goto","if","in","local","nil","not","or","repeat","return","then","true","until","while"};
    for(u64 w=0;w<sizeof(words)/sizeof(words[0]);w++){
        u64 i=0; while(words[w][i]&&i<n&&words[w][i]==s[i])i++;
        if(i==n&&!words[w][i])return 1;
    }
    return 0;
}
static void color(const char *s){ write_s("\x1b[");write_s(s);write_s("m"); }
static void render_code(u64 a,u64 b) {
    for(u64 i=a;i<b;){
        if(i+1<b&&text[i]=='-'&&text[i+1]=='-'){color("90");while(i<b&&text[i]!='\n')write_c(text[i++]);color("0");continue;}
        if(text[i]=='\''||text[i]=='\"'){char q=text[i];color("32");write_c(text[i++]);while(i<b){char c=text[i++];write_c(c);if(c=='\\'&&i<b)write_c(text[i++]);else if(c==q)break;}color("0");continue;}
        if(text[i]>='0'&&text[i]<='9'){color("35");while(i<b&&((text[i]>='0'&&text[i]<='9')||text[i]=='.'))write_c(text[i++]);color("0");continue;}
        if(alpha(text[i])){u64 start=i;while(i<b&&alnum(text[i]))i++;if(keyword(text+start,i-start))color("36;1");while(start<i)write_c(text[start++]);color("0");continue;}
        write_c(text[i++]);
    }
}
static u64 line_start(u64 line){u64 p=0;while(line&&p<length){if(text[p++]=='\n')line--;}return p;}
static u64 cursor_line(void){u64 n=0;for(u64 i=0;i<cursor;i++)if(text[i]=='\n')n++;return n;}
static u64 cursor_col(void){u64 p=cursor;while(p&&text[p-1]!='\n')p--;return cursor-p;}
static void redraw(void){
    write_s("\x1b[2J\x1b[H\x1b[44;37;1m DimensionEdit ");write_s(path);write_s(dirty?"  [modified]":(existing_file?"":"  [new file]"));write_s("\x1b[K\x1b[0m\n");
    u64 p=line_start(scroll_line);
    for(u64 row=0;row<VIEW_ROWS;row++){
        u64 end=p;while(end<length&&text[end]!='\n')end++;
        render_code(p,end);write_s("\x1b[K\n");p=end<length?end+1:end;
    }
    write_s("\x1b[7m Ctrl-S save  Ctrl-Q quit  arrows move\x1b[K\x1b[0m");
    u64 line=cursor_line();u64 col=cursor_col();
    write_s("\x1b[");write_u64(line-scroll_line+2);write_s(";");write_u64(col+1);write_s("H");
}
static void ensure_visible(void){u64 l=cursor_line();if(l<scroll_line)scroll_line=l;else if(l>=scroll_line+VIEW_ROWS)scroll_line=l-VIEW_ROWS+1;}
static void position_cursor(void){u64 line=cursor_line(),col=cursor_col();write_s("\x1b[");write_u64(line-scroll_line+2);write_s(";");write_u64(col+1);write_s("H");}
static void redraw_body(void){
    u64 p=line_start(scroll_line);
    for(u64 row=0;row<VIEW_ROWS;row++){
        write_s("\x1b[");write_u64(row+2);write_s(";1H\x1b[K");
        u64 end=p;while(end<length&&text[end]!='\n')end++;
        render_code(p,end);p=end<length?end+1:end;
    }
    position_cursor();
}
static void redraw_current_line(void){
    u64 line=cursor_line();
    if(line<scroll_line||line>=scroll_line+VIEW_ROWS){redraw();return;}
    u64 start=line_start(line),end=start;while(end<length&&text[end]!='\n')end++;
    write_s("\x1b[");write_u64(line-scroll_line+2);write_s(";1H\x1b[K");
    render_code(start,end);position_cursor();
}
static void move_vertical(int delta){u64 col=cursor_col(),line=cursor_line();if(delta<0){if(!line)return;line--;}else{u64 e=cursor;while(e<length&&text[e]!='\n')e++;if(e==length)return;line++;}u64 p=line_start(line),e=p;while(e<length&&text[e]!='\n')e++;cursor=p+(col<e-p?col:e-p);}
static void insert(char c){if(length>=CAPACITY-1)return;for(u64 i=length;i>cursor;i--)text[i]=text[i-1];text[cursor++]=c;length++;dirty=1;}
static void backspace(void){if(!cursor)return;for(u64 i=cursor-1;i<length-1;i++)text[i]=text[i+1];cursor--;length--;dirty=1;}
static int save(void){i64 fd=(i64)call2(SYS_OPEN,(u64)path,O_WRITE|O_CREATE|O_TRUNC);if(fd<0)return 0;i64 n=(i64)call3(SYS_FD_WRITE,fd,(u64)text,length);call2(SYS_CLOSE,fd,0);if(n==(i64)length){dirty=0;return 1;}return 0;}
static void copy_path(const char*s){u64 i=0;while(s[i]&&i+1<PATH_SIZE){path[i]=s[i];i++;}path[i]=0;}

__attribute__((noreturn)) void _start(void){
    parse_args();u64 first=0;if(argc()&&(!strcmp(arg_at(0),"edit")||!strcmp(arg_at(0),"/bin/edit")))first=1;
    if(first>=argc()){write_s("usage: edit FILE\n");call2(SYS_EXIT,1,0);__builtin_unreachable();}
    copy_path(arg_at(first));i64 fd=(i64)call2(SYS_OPEN,(u64)path,O_READ);if(fd>=0){existing_file=1;i64 n=(i64)call3(SYS_FD_READ,fd,(u64)text,CAPACITY-1);if(n>0)length=(u64)n;call2(SYS_CLOSE,fd,0);}
    i64 kbd=(i64)call2(SYS_OPEN,(u64)"/dev/kbd",O_READ);if(kbd<0){write_s("edit: no keyboard\n");call2(SYS_EXIT,1,0);__builtin_unreachable();}
    redraw();for(;;){char c;if((i64)call3(SYS_FD_READ,kbd,(u64)&c,1)!=1)continue;
        if((unsigned char)c==19){save();redraw();continue;}if((unsigned char)c==17){if(!dirty)break;write_s("\x1b[24;1H\x1b[41;37m Unsaved changes: Ctrl-S then Ctrl-Q \x1b[K\x1b[0m");continue;}
        if(c==27){char b=0,key=0;if((i64)call3(SYS_FD_READ,kbd,(u64)&b,1)!=1||b!='['||(i64)call3(SYS_FD_READ,kbd,(u64)&key,1)!=1)continue;u64 old_scroll=scroll_line;if(key=='D'&&cursor)cursor--;else if(key=='C'&&cursor<length)cursor++;else if(key=='A')move_vertical(-1);else if(key=='B')move_vertical(1);ensure_visible();if(old_scroll!=scroll_line)redraw_body();else position_cursor();continue;}
        u64 old_scroll=scroll_line;
        if(c=='\r'||c=='\n'){insert('\n');ensure_visible();redraw_body();continue;}
        if(c=='\b'||c==127)backspace();else if(c=='\t') {insert(' ');insert(' ');} else if(c>=32&&c<127)insert(c);ensure_visible();if(old_scroll!=scroll_line)redraw();else redraw_current_line();
    }write_s("\x1b[2J\x1b[H");call2(SYS_CLOSE,kbd,0);call2(SYS_EXIT,0,0);__builtin_unreachable();
}

#ifndef LLPL_MATH_H
#define LLPL_MATH_H
#define HUGE_VAL (1.7976931348623157e+308)
#define HUGE_VALF (3.402823466e+38f)
#define INFINITY HUGE_VALF
#define NAN (0.0/0.0)
#define isnan(x) ((x)!=(x))
#define isinf(x) ((x)==HUGE_VAL||(x)==-HUGE_VAL)
double fabs(double); double floor(double); double ceil(double); double fmod(double,double);
double frexp(double,int*); double ldexp(double,int); double modf(double,double*);
double sqrt(double); double sin(double); double cos(double); double tan(double);
double asin(double); double acos(double); double atan(double); double atan2(double,double);
double exp(double); double log(double); double log10(double); double log2(double);
double pow(double,double);
#endif

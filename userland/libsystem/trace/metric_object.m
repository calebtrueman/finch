/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#import <os/object.h>
extern void *_os_object_alloc_realized(const void *,size_t);
#include <stdlib.h>
#include "metric.h"
@interface FinchTraceMetricLabel : OS_object @end
@implementation FinchTraceMetricLabel
-(void)dealloc{struct metric_label*p=(void*)self;free(p->data);free(p->strings);[super dealloc];}
@end
@interface FinchTraceMetricDimensions : OS_object @end
@implementation FinchTraceMetricDimensions
-(void)dealloc{struct metric_dimensions*p=(void*)self;for(unsigned i=0;i<p->count;i++)os_release((id)p->labels[i]);free(p->labels);[super dealloc];}
@end
@interface FinchTraceMetricGroup : OS_object @end
@implementation FinchTraceMetricGroup
-(void)dealloc{struct metric_group*p=(void*)self;if(p->dimensions)os_release((id)p->dimensions);[super dealloc];}
@end
@interface FinchTraceMetric : OS_object @end
@implementation FinchTraceMetric
-(void)dealloc{struct metric*p=(void*)self;os_release((id)p->label);os_release((id)p->group);if(p->dimensions)os_release((id)p->dimensions);[super dealloc];}
@end
void *finch_metric_allocate(unsigned kind,size_t size){Class classes[]={[FinchTraceMetricLabel class],[FinchTraceMetricDimensions class],[FinchTraceMetricGroup class],[FinchTraceMetric class]};return _os_object_alloc_realized(classes[kind],size);}

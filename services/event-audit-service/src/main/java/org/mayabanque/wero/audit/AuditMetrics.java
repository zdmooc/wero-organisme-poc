package org.mayabanque.wero.audit;

import io.micrometer.core.instrument.MeterRegistry;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

@ApplicationScoped
public class AuditMetrics {
    @Inject MeterRegistry registry;

    public void consumed(String eventType) {
        registry.counter("wero.audit.events", "event_type", eventType == null ? "UNKNOWN" : eventType).increment();
    }
}

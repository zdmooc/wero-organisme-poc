package org.mayabanque.wero.payment;

import io.micrometer.core.instrument.MeterRegistry;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

@ApplicationScoped
public class PaymentMetrics {
    @Inject MeterRegistry registry;

    public void paymentStatus(PaymentStatus status) {
        registry.counter("wero.payments.total", "status", status.name()).increment();
    }

    public void idempotentReplay() {
        registry.counter("wero.payments.idempotent.replays").increment();
    }

    public void reconciliation(String outcome) {
        registry.counter("wero.payments.reconciliations", "outcome", outcome).increment();
    }
}

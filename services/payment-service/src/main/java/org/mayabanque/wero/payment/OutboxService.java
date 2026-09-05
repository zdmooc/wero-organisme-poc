package org.mayabanque.wero.payment;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.opentelemetry.api.trace.Span;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import java.time.Instant;
import java.util.UUID;

@ApplicationScoped
public class OutboxService {
    @Inject ObjectMapper objectMapper;

    public void enqueue(PaymentEntity payment, String eventType) {
        enqueue(payment, eventType, null);
    }

    public void enqueue(PaymentEntity payment, String eventType, String correlationId) {
        String eventId = UUID.randomUUID().toString();
        var spanContext = Span.current().getSpanContext();
        String traceId = spanContext.isValid() ? spanContext.getTraceId() : null;
        String traceparent = spanContext.isValid()
                ? "00-" + spanContext.getTraceId() + "-" + spanContext.getSpanId() + (spanContext.isSampled() ? "-01" : "-00")
                : null;
        PaymentEvent event = new PaymentEvent(2, eventId, eventType, payment.paymentId, payment.status.name(),
                payment.amountCents, payment.currency, payment.settlementId, correlationId, traceId, Instant.now());

        OutboxEventEntity row = new OutboxEventEntity();
        row.eventId = eventId;
        row.aggregateType = "PAYMENT";
        row.aggregateId = payment.paymentId;
        row.eventType = eventType;
        row.payload = toJson(event);
        row.correlationId = correlationId;
        row.traceparent = traceparent;
        row.createdAt = event.occurredAt();
        row.publishAttempts = 0;
        row.persist();
    }

    private String toJson(PaymentEvent event) {
        try { return objectMapper.writeValueAsString(event); }
        catch (JsonProcessingException e) { throw new IllegalStateException("Unable to serialize payment event", e); }
    }

    public record PaymentEvent(int schemaVersion, String eventId, String eventType, String paymentId, String status,
                               long amountCents, String currency, String settlementId, String correlationId,
                               String traceId, Instant occurredAt) {}
}

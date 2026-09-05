package org.mayabanque.wero.payment;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import java.time.Instant;
import java.util.UUID;

@ApplicationScoped
public class OutboxService {

    @Inject
    ObjectMapper objectMapper;

    public void enqueue(PaymentEntity payment, String eventType) {
        String eventId = UUID.randomUUID().toString();
        PaymentEvent event = new PaymentEvent(
                1,
                eventId,
                eventType,
                payment.paymentId,
                payment.status.name(),
                payment.amountCents,
                payment.currency,
                payment.settlementId,
                Instant.now());

        OutboxEventEntity row = new OutboxEventEntity();
        row.eventId = eventId;
        row.aggregateType = "PAYMENT";
        row.aggregateId = payment.paymentId;
        row.eventType = eventType;
        row.payload = toJson(event);
        row.createdAt = event.occurredAt();
        row.publishAttempts = 0;
        row.persist();
    }

    private String toJson(PaymentEvent event) {
        try {
            return objectMapper.writeValueAsString(event);
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("Unable to serialize payment event", e);
        }
    }

    public record PaymentEvent(
            int schemaVersion,
            String eventId,
            String eventType,
            String paymentId,
            String status,
            long amountCents,
            String currency,
            String settlementId,
            Instant occurredAt) {}
}

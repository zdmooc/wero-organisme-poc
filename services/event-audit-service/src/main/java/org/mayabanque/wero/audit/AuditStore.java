package org.mayabanque.wero.audit;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import jakarta.transaction.Transactional;
import java.time.Instant;
import org.apache.kafka.clients.consumer.ConsumerRecord;

@ApplicationScoped
public class AuditStore {
    @Inject ObjectMapper objectMapper;
    @Inject AuditMetrics metrics;

    @Transactional
    public void store(ConsumerRecord<String, String> record) {
        try {
            JsonNode json = objectMapper.readTree(record.value());
            String eventId = json.path("eventId").asText(null);
            String paymentId = json.path("paymentId").asText(null);
            String eventType = json.path("eventType").asText(null);
            String status = json.path("status").asText(null);
            String correlationId = json.path("correlationId").asText(null);
            String traceId = json.path("traceId").asText(null);

            if (eventId == null || paymentId == null || eventType == null) {
                throw new IllegalArgumentException("Invalid payment event payload");
            }
            if (AuditEventEntity.count("eventId", eventId) > 0) return;

            AuditEventEntity entity = new AuditEventEntity();
            entity.eventId = eventId;
            entity.paymentId = paymentId;
            entity.eventType = eventType;
            entity.paymentStatus = status;
            entity.correlationId = correlationId;
            entity.traceId = traceId;
            entity.payload = record.value();
            entity.kafkaPartition = record.partition();
            entity.kafkaOffset = record.offset();
            entity.receivedAt = Instant.now();
            entity.persist();
            metrics.consumed(eventType);
        } catch (Exception e) {
            throw new IllegalStateException("Unable to persist Kafka audit event", e);
        }
    }
}

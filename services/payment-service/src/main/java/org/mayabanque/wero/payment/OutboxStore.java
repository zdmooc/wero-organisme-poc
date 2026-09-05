package org.mayabanque.wero.payment;

import io.quarkus.panache.common.Page;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.transaction.Transactional;
import java.time.Instant;
import java.util.List;

@ApplicationScoped
public class OutboxStore {

    @Transactional
    public List<PendingEvent> loadPending(int batchSize) {
        return OutboxEventEntity.find("publishedAt is null order by id")
                .page(Page.ofSize(batchSize))
                .list()
                .stream()
                .map(entity -> new PendingEvent(
                        entity.id,
                        entity.aggregateId,
                        entity.eventId,
                        entity.payload,
                        entity.correlationId,
                        entity.traceparent))
                .toList();
    }

    @Transactional(Transactional.TxType.REQUIRES_NEW)
    public void markPublished(Long id) {
        OutboxEventEntity row = OutboxEventEntity.findById(id);
        if (row == null || row.publishedAt != null) {
            return;
        }
        row.publishedAt = Instant.now();
        row.publishAttempts++;
        row.lastError = null;
    }

    @Transactional(Transactional.TxType.REQUIRES_NEW)
    public void markFailed(Long id, String error) {
        OutboxEventEntity row = OutboxEventEntity.findById(id);
        if (row == null || row.publishedAt != null) {
            return;
        }
        row.publishAttempts++;
        row.lastError = error;
    }

    public record PendingEvent(
            Long id,
            String aggregateId,
            String eventId,
            String payload,
            String correlationId,
            String traceparent) {
    }
}

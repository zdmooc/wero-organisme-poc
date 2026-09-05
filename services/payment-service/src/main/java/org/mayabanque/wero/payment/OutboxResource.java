package org.mayabanque.wero.payment;

import jakarta.transaction.Transactional;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import java.time.Instant;
import java.util.List;

@Path("/outbox")
@Produces(MediaType.APPLICATION_JSON)
public class OutboxResource {

    @GET
    @Path("/{paymentId}")
    @Transactional
    public List<OutboxEventView> byPayment(@PathParam("paymentId") String paymentId) {
        List<OutboxEventEntity> rows = OutboxEventEntity.list("aggregateId = ?1 order by id", paymentId);
        return rows.stream()
                .map(r -> new OutboxEventView(
                        r.id,
                        r.eventId,
                        r.eventType,
                        r.aggregateId,
                        r.createdAt,
                        r.publishedAt,
                        r.publishAttempts,
                        r.lastError))
                .toList();
    }

    public record OutboxEventView(
            Long id,
            String eventId,
            String eventType,
            String paymentId,
            Instant createdAt,
            Instant publishedAt,
            int publishAttempts,
            String lastError) {}
}

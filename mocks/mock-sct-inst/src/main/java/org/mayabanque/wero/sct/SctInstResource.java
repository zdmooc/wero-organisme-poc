package org.mayabanque.wero.sct;

import io.opentelemetry.api.trace.Span;
import jakarta.ws.rs.*;
import jakarta.ws.rs.core.MediaType;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import org.jboss.logging.Logger;

@Path("/sct-inst/transfers")
@Consumes(MediaType.APPLICATION_JSON)
@Produces(MediaType.APPLICATION_JSON)
public class SctInstResource {
    private static final Logger LOG = Logger.getLogger(SctInstResource.class);
    private static final Map<String, TransferStatus> TRANSFERS = new ConcurrentHashMap<>();

    @POST
    public TransferResponse transfer(@HeaderParam("X-Correlation-Id") String correlationId, TransferRequest request) {
        Span.current().setAttribute("wero.payment_id", request.paymentId());
        if (correlationId != null) Span.current().setAttribute("wero.correlation_id", correlationId);
        LOG.infof("correlationId=%s paymentId=%s sct-inst mode=%s", correlationId, request.paymentId(), request.simulateMode());
        if ("FAIL_BEFORE_SETTLEMENT".equalsIgnoreCase(request.simulateMode())) return new TransferResponse(null, "FAILED");
        TransferStatus stored = TRANSFERS.computeIfAbsent(request.paymentId(),
                id -> new TransferStatus(id, "SETTLED", "SCT-" + UUID.randomUUID()));
        if ("TIMEOUT_AFTER_SETTLEMENT".equalsIgnoreCase(request.simulateMode())) {
            try { Thread.sleep(5000); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
        }
        return new TransferResponse(stored.settlementId(), stored.status());
    }

    @GET @Path("/{paymentId}")
    public TransferStatus status(@HeaderParam("X-Correlation-Id") String correlationId,
                                 @PathParam("paymentId") String paymentId) {
        Span.current().setAttribute("wero.payment_id", paymentId);
        if (correlationId != null) Span.current().setAttribute("wero.correlation_id", correlationId);
        return TRANSFERS.getOrDefault(paymentId, new TransferStatus(paymentId, "NOT_FOUND", null));
    }

    public record TransferRequest(String paymentId, long amountCents, String currency, String simulateMode) {}
    public record TransferResponse(String settlementId, String status) {}
    public record TransferStatus(String paymentId, String status, String settlementId) {}
}

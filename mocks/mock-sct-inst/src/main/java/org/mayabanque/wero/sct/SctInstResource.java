package org.mayabanque.wero.sct;

import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.PathParam;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

@Path("/sct-inst/transfers")
@Consumes(MediaType.APPLICATION_JSON)
@Produces(MediaType.APPLICATION_JSON)
public class SctInstResource {

    private static final Map<String, TransferStatus> TRANSFERS = new ConcurrentHashMap<>();

    @POST
    public TransferResponse transfer(TransferRequest request) {
        if ("FAIL_BEFORE_SETTLEMENT".equalsIgnoreCase(request.simulateMode())) {
            return new TransferResponse(null, "FAILED");
        }

        TransferStatus stored = TRANSFERS.computeIfAbsent(
                request.paymentId(),
                id -> new TransferStatus(id, "SETTLED", "SCT-" + UUID.randomUUID()));

        if ("TIMEOUT_AFTER_SETTLEMENT".equalsIgnoreCase(request.simulateMode())) {
            try {
                // The rail has already committed the transfer, but the caller loses the response.
                // This is the classic UNKNOWN case that must be reconciled, never blindly replayed.
                Thread.sleep(5000);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }

        return new TransferResponse(stored.settlementId(), stored.status());
    }

    @GET
    @Path("/{paymentId}")
    public TransferStatus status(@PathParam("paymentId") String paymentId) {
        return TRANSFERS.getOrDefault(paymentId, new TransferStatus(paymentId, "NOT_FOUND", null));
    }

    public record TransferRequest(String paymentId, long amountCents, String currency, String simulateMode) {}
    public record TransferResponse(String settlementId, String status) {}
    public record TransferStatus(String paymentId, String status, String settlementId) {}
}

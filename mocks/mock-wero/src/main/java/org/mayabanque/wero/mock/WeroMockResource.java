package org.mayabanque.wero.mock;

import io.opentelemetry.api.trace.Span;
import jakarta.inject.Inject;
import jakarta.ws.rs.*;
import jakarta.ws.rs.core.MediaType;
import org.eclipse.microprofile.rest.client.inject.RestClient;
import org.jboss.logging.Logger;

@Path("/wero/payments")
@Consumes(MediaType.APPLICATION_JSON)
@Produces(MediaType.APPLICATION_JSON)
public class WeroMockResource {
    private static final Logger LOG = Logger.getLogger(WeroMockResource.class);
    @Inject @RestClient SctInstClient sctInst;

    @POST
    public PaymentResponse pay(@HeaderParam("X-Correlation-Id") String correlationId, PaymentRequest request) {
        Span.current().setAttribute("wero.payment_id", request.paymentId());
        if (correlationId != null) Span.current().setAttribute("wero.correlation_id", correlationId);
        LOG.infof("correlationId=%s paymentId=%s mock-wero forward", correlationId, request.paymentId());
        var settlement = sctInst.transfer(correlationId,
                new TransferRequest(request.paymentId(), request.amountCents(), request.currency(), request.simulateMode()));
        return new PaymentResponse(request.paymentId(), settlement.status(), settlement.settlementId());
    }

    public record PaymentRequest(String paymentId, long amountCents, String currency, String debtorAlias,
                                 String creditorAlias, String simulateMode) {}
    public record PaymentResponse(String paymentId, String status, String settlementId) {}
    public record TransferRequest(String paymentId, long amountCents, String currency, String simulateMode) {}
    public record TransferResponse(String settlementId, String status) {}
}
